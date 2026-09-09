{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
  python = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.pyyaml ]);
in
{
  options.programs.ai-agents.codexSkills = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    readOnly = true;
    internal = true;
  };

  config.programs.ai-agents.codexSkills = lib.mapAttrs (
    name: source:
    pkgs.runCommandLocal "codex-skill-${name}" { inherit source; } ''
      cp -RL "$source" "$out"
      chmod -R u+w "$out"
      ${python}/bin/python ${./skill_adapter.py} --skill-dir "$out"
    ''
  ) cfg.skills;
}
