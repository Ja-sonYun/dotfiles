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
  imports = [
    ./autocommit.nix
    ./worktree.nix
    ./zsh.nix
  ];

  options.programs.gitExtend = {
    enable = lib.mkEnableOption "custom Git commands";
    restrictLinkedWorktreeBranchSwitching = lib.mkEnableOption "branch-switch restrictions in linked worktrees";
    commands = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.listOf lib.types.nonEmptyStr;
            };
            flag = lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "Extension flag recognized only immediately after the command path.";
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
  };

  config = lib.mkIf cfg.enable {
    programs.git.package = pkgs.git-extend.override {
      inherit (cfg) commands restrictLinkedWorktreeBranchSwitching;
    };
  };
}
