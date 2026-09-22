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
  clients =
    lib.optional config.programs.claude-code.enable "claude"
    ++ lib.optional config.programs.codex.enable "codex"
    ++ lib.optional config.programs.pi.enable "pi";
  modelMapFile = jsonFormat.generate "ai-agent-model-map.json" (
    lib.filterAttrs (client: _: builtins.elem client clients) cfg.modelMap
  );
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
      --claude-plugin ${lib.escapeShellArg config.programs.claude-code.mcpPluginName} \
      ${lib.escapeShellArgs (
        lib.concatMap (client: [
          "--client"
          client
        ]) clients
      )}

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
  options.programs.ai-agents = {
    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };

    modelMap = lib.mkOption {
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
      default = { };
      description = "Per-client model and reasoning mappings for portable custom agent tiers.";
    };

    adaptedAgents = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      readOnly = true;
      internal = true;
    };
  };

  config = lib.mkMerge [
    {
      programs.ai-agents.adaptedAgents =
        if cfg.enable && cfg.agentsDir != null && clients != [ ] then adaptedAgents else null;
    }

    (lib.mkIf (cfg.enable && cfg.adaptedAgents != null) (
      lib.mkMerge [
        (lib.mkIf config.programs.codex.enable {
          programs.codex.agentsDir = "${cfg.adaptedAgents}/codex";
        })

        (lib.mkIf config.programs.claude-code.enable {
          programs.claude-code.agentsDir = "${cfg.adaptedAgents}/claude";
        })

        (lib.mkIf config.programs.pi.enable {
          programs.pi.agentsDir = "${cfg.adaptedAgents}/pi";
        })
      ]
    ))
  ];
}
