{
  hasTag,
  lib,
  ...
}:
{
  imports = [
    ./zsh
    ./core
    ./fonts.nix

    ./programs/analysis-tools
    ./programs/git
    ./programs/jujutsu
    ./programs/logging.nix
    ./programs/tmux
    ./programs/direnv
    ./programs/navi
    ./programs/visidata
    ./programs/radare2
  ]
  ++ lib.optionals (hasTag "task") [ ./programs/taskwarrior ]
  ++ lib.optionals (hasTag "gui") [
    ./programs/ghostty
    ./programs/weechat
  ]
  ++ lib.optionals (hasTag "ai") [
    ./programs/agent
    ./programs/ai-tools
    ./programs/antigravity-cli
    ./programs/claude
    ./programs/codex
    ./programs/open-code-review
  ];

  home.file.profile = {
    target = ".profile";
    text = "";
  };
}
