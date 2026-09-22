{
  lib,
  pkgs,
  ...
}:
{
  options.programs.tmux.extensions.gitPr = {
    enable = lib.mkEnableOption "GitHub pull request lookup for tmux";
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      default = pkgs.writeShellApplication {
        name = "tmux-git-pr";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.flock
          pkgs.gh
          pkgs.git
        ];
        text = builtins.readFile ./scripts/git-pr;
      };
    };
  };
}
