{ hasTag, ... }:
{
  programs.ai-agents.extensions.orchestration = {
    enable = hasTag "ai";
    model = "openai/gpt-6-astra";
    notifications.enable = hasTag "ai";
  };
  programs.tmux.extensions.agent.orchestration = {
    enable = hasTag "ai";
    menuKey = "A";
  };
}
