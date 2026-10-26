{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.ai-agents;
  native = config.programs.antigravity-cli;
  syncLib = import ../sync.nix { inherit lib; };
  selectedAgents = syncLib.select "programs.antigravity-cli.sync.agents" native.sync.agents (
    lib.genAttrs cfg.agentNames (_: null)
  );
in
{
  config = lib.mkIf (cfg.enable && native.enable) {
    programs.ai-agents.modelMap.antigravity = lib.genAttrs [ "xhigh" "high" "middle" "low" ] (_: {
      model = lib.mkDefault "inherit";
    });
    programs.antigravity-cli = {
      inherit (cfg) agentNames;
      agentsDir = lib.mkIf (
        cfg.adaptedAgents != null && selectedAgents != { }
      ) "${cfg.adaptedAgents}/antigravity";
      skills = syncLib.select "programs.antigravity-cli.sync.skills" native.sync.skills cfg.skills;
      mcpServers = cfg.mcp.rendered.antigravity;
    };
  };
}
