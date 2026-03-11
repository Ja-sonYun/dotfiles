{ lib, purpose, ... }:
{
  imports = [
    ./zsh
    ./core
    ./secrets # Agenix secrets management

    ./programs/git
    ./programs/git/utils.nix
    ./programs/jujutsu
    ./programs/tmux
    ./programs/direnv
    ./programs/navi
    ./programs/opencode
  ]
  ++ lib.optionals (purpose == "main") [
    ./analysis

    ./programs/ghostty
    ./programs/weechat
    ./programs/claude
    ./programs/codex
    ./programs/visidata
  ];

  home.file.profile = {
    target = ".profile";
    text = "";
  };
}
