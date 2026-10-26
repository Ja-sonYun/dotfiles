{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.ai-agents;
in
{
  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && config.programs.claude-code.enable) {
      programs.claude-code = lib.mkMerge [
        {
          inherit (cfg) extraPath skills;
          mcpServers = cfg.mcp.rendered.claude;
          settings.disabledMcpjsonServers = cfg.mcp.rendered.disabledMcpServers;
        }
        (lib.mkIf (cfg.context != null) {
          inherit (cfg) context;
        })
        (lib.mkIf (cfg.customInstructions != "") {
          customInstructions = lib.mkBefore cfg.customInstructions;
        })
        (lib.mkIf (cfg.adaptedAgents != null) {
          agentsDir = "${cfg.adaptedAgents}/claude";
          inherit (cfg) agentNames;
        })
      ];
    })
  ];
}
