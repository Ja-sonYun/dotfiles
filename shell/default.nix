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
    ./programs/jujutsu
    ./programs/tmux
    ./programs/direnv
    ./programs/navi
    ./programs/visidata
    ./programs/radare2

    ./programs/ghostty
    ./programs/claude
    ./programs/codex
    ./programs/pi
    ./programs/open-code-review

    "${agenix-secrets}/modules/mcp"
  ]
  ++ lib.optionals (purpose == "main") [
    ./programs/weechat
  ];

  home.file.profile = {
    target = ".profile";
    text = "";
  };
}
