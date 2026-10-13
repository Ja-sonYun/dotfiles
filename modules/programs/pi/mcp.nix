{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi;
  jsonFormat = pkgs.formats.json { };
in
{
  options.programs.pi.mcp.servers = lib.mkOption {
    type = lib.types.attrsOf jsonFormat.type;
    default = { };
    description = "Servers for Pi's built-in MCP extension.";
  };

  config = lib.mkIf (cfg.enable && cfg.mcp.servers != { }) {
    home.file =
      lib.genAttrs
        (
          [ ".pi/agent/mcp.json" ] ++ lib.optional (cfg.dev.extensionsSource != null) ".pi/agent-dev/mcp.json"
        )
        (_: {
          source = jsonFormat.generate "pi-mcp.json" {
            mcpServers = cfg.mcp.servers;
          };
        });
  };
}
