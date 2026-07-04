{
  lib,
  purpose,
  agenix-secrets,
  ...
}:
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
    ./programs/radare2
  ]
  ++ lib.optionals (purpose == "main") [
    ./programs/ghostty
    ./programs/weechat
    ./programs/claude
    ./programs/codex
    ./programs/pi
    ./programs/open-code-review

    "${agenix-secrets}/modules/mcp"
  ];

  home.file.profile = {
    target = ".profile";
    text = "";
  };
}
