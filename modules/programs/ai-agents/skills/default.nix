{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];
  python = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.pyyaml ]);

  skillRootsAt =
    relativePath:
    let
      path = if relativePath == "" then cfg.skillsDir else cfg.skillsDir + "/${relativePath}";
    in
    if builtins.pathExists (path + "/SKILL.md") then
      [ relativePath ]
    else
      lib.concatMap (
        name: skillRootsAt (if relativePath == "" then name else "${relativePath}/${name}")
      ) (builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir path)));

  skillRoots = if cfg.skillsDir == null then [ ] else skillRootsAt "";
  skillName =
    relativePath: builtins.baseNameOf (if relativePath == "" then cfg.skillsDir else relativePath);
  skillNames = map skillName skillRoots;
  duplicateSkillNames = lib.unique (
    lib.filter (name: lib.count (candidate: candidate == name) skillNames > 1) skillNames
  );

  skills =
    if duplicateSkillNames != [ ] then
      throw "Duplicate AI agent skill names: ${lib.concatStringsSep ", " duplicateSkillNames}."
    else
      builtins.listToAttrs (
        map (
          relativePath: lib.nameValuePair (skillName relativePath) (cfg.skillsDir + "/${relativePath}")
        ) skillRoots
      );
in
{
  options.programs.ai-agents = {
    skillsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Directory searched recursively for skill directories.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
    };

    codexSkills = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      internal = true;
    };
  };

  config = lib.mkMerge [
    {
      programs.ai-agents.skills = skills;
      programs.ai-agents.codexSkills = lib.mapAttrs (
        name: source:
        pkgs.runCommandLocal "codex-skill-${name}" { inherit source; } ''
          cp -RL "$source" "$out"
          chmod -R u+w "$out"
          ${python}/bin/python ${./skill_adapter.py} --skill-dir "$out"
        ''
      ) cfg.skills;
    }

    (lib.mkIf cfg.enable (
      lib.mkMerge [
        (lib.mkIf config.programs.codex.enable {
          programs.codex.skills = cfg.codexSkills;
        })

        (lib.mkIf config.programs.claude-code.enable {
          programs.claude-code.skills = cfg.skills;
        })

        (lib.mkIf config.programs.pi.enable {
          programs.pi.skills = cfg.skills;
        })
      ]
    ))
  ];
}
