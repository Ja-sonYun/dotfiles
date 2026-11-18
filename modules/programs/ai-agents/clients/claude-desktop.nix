{
  config,
  lib,
  ...
}:
{
  config = lib.mkIf (config.programs.ai-agents.enable && config.programs.claude-desktop.enable) {
    programs.claude-desktop.settings.mcpServers =
      builtins.removeAttrs config.programs.ai-agents.mcp.rendered.claudeDesktop
        (config.programs.claude-code.settings.disabledMcpjsonServers or [ ]);
  };
}
