{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux.extensions;
  enabled = lib.any (name: cfg.${name}.enable) [
    "agent"
    "popup"
    "monitor"
    "shell"
    "watch"
    "sessionCleanup"
    "gitPr"
  ];
in
{
  imports = [
    ./agent
    ./popup
    ./monitor
    ./shell
    ./watch
    ./session-cleanup
    ./git-pr
  ];
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = config.programs.tmux.enable;
        message = "tmux extensions require programs.tmux.enable.";
      }
    ];
    home.packages = [
      pkgs.bash
      pkgs.coreutils
      pkgs.flock
      pkgs.pstree
    ];
  };
}
