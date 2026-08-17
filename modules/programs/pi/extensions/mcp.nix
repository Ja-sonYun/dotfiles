{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi;
  jsonFormat = pkgs.formats.json { };
  agentDir = ".pi/agent";
in
{
  options.programs.pi.mcp = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pi-extensions.mcp-adapter;
      description = "pi-mcp-adapter extension package.";
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = "Settings written to the Pi MCP configuration.";
    };

    servers = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = "MCP servers written to the Pi MCP configuration.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.mcp.servers != { }) {
    programs.pi.extensions.mcp-adapter = "${cfg.mcp.package}/extension";
    home.file."${agentDir}/mcp.json".source = jsonFormat.generate "pi-mcp.json" {
      inherit (cfg.mcp) settings;
      mcpServers = cfg.mcp.servers;
    };
  };
}
