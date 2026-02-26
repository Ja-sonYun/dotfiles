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
    ./programs/visidata
    ./programs/direnv
    ./programs/navi
    ./programs/opencode
  ]
  ++ lib.optionals (purpose == "main") [
    ./programs/ghostty
    ./programs/weechat
    ./programs/claude
    ./programs/codex
  ];

  home.file.profile = {
    target = ".profile";
    text = "";
  };
}
