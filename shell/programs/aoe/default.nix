{
  programs.aoe = {
    enable = true;

    settings.session.agent_command_override = {
      codex = "direnv exec . codex";
      claude = "direnv exec . claude";
      pi = "direnv exec . pi";
    };
  };
}
