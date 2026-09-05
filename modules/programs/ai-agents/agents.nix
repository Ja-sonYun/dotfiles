{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
  jsonFormat = pkgs.formats.json { };
  python = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.pyyaml ]);
  modelMapFile = jsonFormat.generate "ai-agent-model-map.json" cfg.modelMap;
  mcpServersFile = jsonFormat.generate "ai-agent-mcp-servers.json" {
    servers = builtins.attrNames cfg.mcp.servers;
    codex_servers = config.programs.codex.settings.mcp_servers or { };
  };
  adaptedAgents = pkgs.runCommandLocal "adapted-ai-agents" { } ''
    set -euo pipefail
    shopt -s nullglob

    ${python}/bin/python ${./agent_adapter.py} \
      --source-dir ${cfg.agentsDir} \
      --output-dir "$out" \
      --model-map ${modelMapFile} \
      --mcp-servers ${mcpServersFile} \
      --claude-plugin hm

    for source in "$out"/codex/*.json; do
      target="''${source%.json}.toml"
      ${pkgs.yq-go}/bin/yq \
        --input-format=json \
        --output-format=toml \
        '.' "$source" > "$target"
      rm "$source"
    done
  '';
in
{
  options.programs.ai-agents.modelMap = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.attrsOf (
        lib.types.submodule {
          options = {
            model = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Client model identifier.";
            };
            reasoning_effort = lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "Optional reasoning effort supported by the client and model.";
            };
          };
        }
      )
    );
    description = "Per-client model and reasoning mappings for portable custom agent tiers.";
  };

  options.programs.ai-agents.adaptedAgents = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    readOnly = true;
    internal = true;
  };

  config.programs.ai-agents.adaptedAgents =
    if cfg.enable && cfg.agentsDir != null then adaptedAgents else null;
}
