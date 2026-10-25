{ config, hasTag, ... }:
{
  programs.ai-agents.extensions.notification.mcp.enable =
    hasTag "ai"
    && !(
      config.programs.ai-agents.extensions.orchestration.enable
      && config.programs.ai-agents.extensions.orchestration.notifications.enable
    );
}
