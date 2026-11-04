{
  config,
  lib,
  pkgs,
  username,
  userhome,
  ...
}:
let
  cfg = config.services.apple-mcp;
in
{
  options.services.apple-mcp = {
    enable = lib.mkEnableOption "the combined Apple HTTP MCP gateway";
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Runtime Reminders token file; required when enabled.";
    };
    allowedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      description = "Additional allowed HTTP hosts alongside loopback hosts.";
    };
    allowedOrigins = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      description = "Allowed HTTP origins.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile != null;
        message = "Apple MCP requires services.apple-mcp.tokenFile.";
      }
      {
        assertion = config.services.apple-calendar.enable && config.services.apple-reminders.enable;
        message = "Apple MCP requires both Calendar and Reminders services.";
      }
    ];
    home-manager.users.${username} = {
      launchd.agents.apple-mcp = {
        enable = true;
        config = {
          ProgramArguments = [ "${pkgs.apple-mcp}/bin/apple-mcp" ];
          EnvironmentVariables = {
            APPLE_MCP_TOKEN_FILE = cfg.tokenFile;
            APPLE_MCP_ALLOWED_HOSTS = builtins.toJSON cfg.allowedHosts;
            APPLE_MCP_ALLOWED_ORIGINS = builtins.toJSON cfg.allowedOrigins;
          };
          RunAtLoad = true;
          KeepAlive = true;
          LimitLoadToSessionType = "Aqua";
          StandardOutPath = "${userhome}/Library/Logs/apple-mcp.log";
          StandardErrorPath = "${userhome}/Library/Logs/apple-mcp.log";
        };
      };
    };
  };
}
