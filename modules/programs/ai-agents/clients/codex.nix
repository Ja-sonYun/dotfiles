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
    {
      programs.ai-agents.mcp.codexServers =
        if cfg.enable && config.programs.codex.enable then
          config.programs.codex.settings.mcp_servers or { }
        else
          { };
    }
    (lib.mkIf (cfg.enable && config.programs.codex.enable) {
      programs.codex = lib.mkMerge [
        {
          inherit (cfg) extraPath;
          skills = cfg.codexSkills;
          settings.mcp_servers = cfg.mcp.rendered.codex;
        }
        (lib.mkIf (cfg.context != null) {
          inherit (cfg) context;
        })
        (lib.mkIf (cfg.customInstructions != "") {
          customInstructions = lib.mkBefore cfg.customInstructions;
        })
        (lib.mkIf (cfg.adaptedAgents != null) {
          agentsDir = "${cfg.adaptedAgents}/codex";
          inherit (cfg) agentNames;
        })
      ];
    })
  ];
}
