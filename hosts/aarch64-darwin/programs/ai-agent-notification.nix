{ hasTag, ... }:
{
  programs.ai-agents.extensions.notification.mcp.enable = hasTag "ai";
}
