{ lib, purpose, ... }:
{
  imports = [
    ./zsh
    ./core
    ./secrets # Agenix secrets management

    ./analysis

    ./programs/git
    ./programs/git/utils.nix
    # We'll use orbstack on macOS
    # ./programs/docker
    ./programs/jujutsu
    ./programs/tmux
    ./programs/visidata
    ./programs/direnv
    ./programs/navi
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
