{ lib, purpose, ... }:
{
  imports = [
    ./zsh
    ./core
    ./secrets # Agenix secrets management

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
    ./programs/claude
    ./programs/codex
  ];

  home.file.profile = {
    target = ".profile";
    text = "";
  };
}
