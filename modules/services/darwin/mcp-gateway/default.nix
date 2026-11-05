{
  config,
  lib,
  pkgs,
  username,
  userhome,
  ...
}:
let
  cfg = config.services.mcp-gateway;
  start = pkgs.writeShellScript "mcp-gateway-start" ''
    exec ${pkgs.mcp-gateway}/bin/mcp-gateway \
      --credentials "${cfg.credentialsFile}" \
      --state ${lib.escapeShellArg "${userhome}/Library/Application Support/mcp-gateway"} \
      --owner-sub ${lib.escapeShellArg cfg.ownerSub} \
      --firecrawl-key "${cfg.firecrawlKeyFile}" \
      --n8n-url "${cfg.n8nUrlFile}" \
      --n8n-key "${cfg.n8nKeyFile}"
  '';
in
{
  options.services.mcp-gateway = {
    enable = lib.mkEnableOption "the internal OAuth MCP gateway; disabling unloads its agent and preserves OAuth state";
    credentialsFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime Caddy Google OAuth environment file.";
    };
    firecrawlKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime Firecrawl API key file.";
    };
    n8nUrlFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime personal n8n API URL file.";
    };
    n8nKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime personal n8n API key file.";
    };
    ownerSub = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Allowed Google subject; empty denies all MCP access and logs authenticated identity for setup.";
    };
  };
  config = {
    assertions = lib.optionals cfg.enable [
      {
        assertion = config.services.apple-mcp.enable;
        message = "MCP gateway requires services.apple-mcp.enable.";
      }
    ];
    home-manager.users.${username}.launchd.agents.mcp-gateway = {
      inherit (cfg) enable;
      config = lib.mkIf cfg.enable {
        ProgramArguments = [ "${start}" ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        LimitLoadToSessionType = "Aqua";
        StandardOutPath = "${userhome}/Library/Logs/mcp-gateway.log";
        StandardErrorPath = "${userhome}/Library/Logs/mcp-gateway.log";
      };
    };
  };
}
