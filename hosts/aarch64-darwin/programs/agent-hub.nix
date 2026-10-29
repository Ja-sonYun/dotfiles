{ hasTag, ... }:
{
  programs.ai-agents.extensions.orchestration = {
    enable = hasTag "ai";
    model = "openai/gpt-6.1-terra";
    observerModel = "openai/gpt-6-luna";
    observerThinkingLevel = "off";
    notifications.enable = hasTag "ai";
  };
  programs.tmux.extensions.agent.orchestration = {
    enable = hasTag "ai";
    menuKey = "A";
  };
}
