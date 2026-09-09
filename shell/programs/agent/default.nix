{
  programs.state.commands.agent = {
    key = "defaults.agent";
    default = "codex";
    choices = {
      codex = "codex";
      claude = "claude";
      pi = "pi";
    };
  };
}
