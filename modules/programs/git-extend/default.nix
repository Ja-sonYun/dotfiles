{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.gitExtend;
in
{
  options.programs.gitExtend.commands = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          path = lib.mkOption {
            type = lib.types.listOf lib.types.nonEmptyStr;
          };
          help = lib.mkOption {
            type = lib.types.str;
          };
          command = lib.mkOption {
            type = lib.types.lines;
          };
        };
      }
    );
    default = [ ];
  };

  config.programs.git.package = pkgs.git-extend.override {
    inherit (cfg) commands;
  };
}
