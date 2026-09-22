{
  hasTag,
  lib,
  pkgs,
  ...
}:
let
  mainSession = "main";
in
{
  imports =
    lib.optionals (hasTag "ai") [ ./agent ]
    ++ lib.optionals (hasTag "task") [ ./taskwarrior.nix ]
    ++ [
      ./monitor
      ./popup
      ./shell
      ./watch
    ];

  programs.tmux.extensions = {
    agent = {
      enable = hasTag "ai";
      inherit mainSession;
    };
    popup = {
      enable = true;
      inherit mainSession;
    };
    monitor = {
      enable = pkgs.stdenv.hostPlatform.isDarwin;
      inherit mainSession;
    };
    shell.enable = true;
    watch.enable = pkgs.stdenv.hostPlatform.isDarwin;
    sessionCleanup.enable = true;
    gitPr.enable = true;
  };
}
