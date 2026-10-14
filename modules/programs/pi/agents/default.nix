{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi;
  jsonFormat = pkgs.formats.json { };
  python = pkgs.python3.withPackages (packages: [ packages.pyyaml ]);
  modelMap = jsonFormat.generate "pi-agent-model-map.json" cfg.agents.modelMap;
  mcpServers = jsonFormat.generate "pi-agent-mcp-servers.json" (builtins.attrNames cfg.mcp.servers);
  agents = pkgs.runCommandLocal "pi-agents" { } ''
    ${python}/bin/python ${./agent_adapter.py} \
      --source-dir ${cfg.agents.sourceDir} \
      --output-dir "$out" \
      --model-map ${modelMap} \
      --mcp-servers ${mcpServers}
  '';
in
{
  options.programs.pi.agents = {
    sourceDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Source directory of Pi agent Markdown definitions.";
    };

    modelMap = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            model = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Pi model identifier for this agent tier.";
            };
            reasoning_effort = lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "Pi reasoning effort for this agent tier.";
            };
          };
        }
      );
      default = { };
      description = "Pi models for the xhigh, high, middle, and low agent tiers.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.agents.sourceDir != null) {
    programs.pi.settings.extensions.subagent.agentsDir =
      lib.mkIf cfg.settings.extensions.subagent.enable agents;
  };
}
