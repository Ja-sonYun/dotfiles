{ config, lib, ... }:
let
  cfg = config.programs.pi;
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
  duplicateNames = lib.unique (
    lib.filter (name: lib.count (candidate: candidate == name) skillNames > 1) skillNames
  );
in
{
  options.programs.pi.skillsDir = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = "Root directory containing Pi skill sources.";
  };

  config = lib.mkIf cfg.enable {
    programs.pi.skills =
      if duplicateNames != [ ] then
        throw "Duplicate Pi skill names: ${lib.concatStringsSep ", " duplicateNames}."
      else
        builtins.listToAttrs (
          map (
            relativePath: lib.nameValuePair (skillName relativePath) (cfg.skillsDir + "/${relativePath}")
          ) skillRoots
        );
  };
}
