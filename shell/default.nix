{ lib, purpose, ... }:
{
  imports = [
    ./zsh
    ./core

    ./analysis

    ./programs/git
    ./programs/git/utils.nix
    ./programs/jujutsu
    ./programs/tmux
    ./programs/direnv
    ./programs/navi
    ./programs/visidata
  ]
  ++ lib.optionals (purpose == "main") [
    ./programs/ghostty
    ./programs/weechat
    ./programs/mcp
    ./programs/rtk
    ./programs/claude
    ./programs/codex
    ./programs/pi
    ./programs/open-code-review
  ];

  home.file.profile = {
    target = ".profile";
    text = "";
  };
}
