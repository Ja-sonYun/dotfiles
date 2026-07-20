{
  hasTag,
  lib,
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
  ]
  ++ lib.optionals (hasTag "gui") [
    ./programs/ghostty
    ./programs/weechat
  ]
  ++ lib.optionals (hasTag "ai") [
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
