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
  json = pkgs.formats.json { };
in
{
  options.services.mcp-gateway.instances = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "this MCP gateway instance";
          settings = lib.mkOption {
            inherit (json) type;
            description = "Gateway JSON settings. Supply runtime file paths for credentials and tokens.";
          };
        };
      }
    );
    description = "Independent MCP gateways with their own listener, authentication and backends.";
  };

  config.home-manager.users.${username}.launchd.agents = lib.mapAttrs' (
    name: instance:
    let
      agentName = "mcp-gateway-${name}";
      settingsFile = json.generate "${agentName}.json" instance.settings;
    in
    lib.nameValuePair agentName {
      inherit (instance) enable;
      config = lib.mkIf instance.enable {
        ProgramArguments = [
          "${pkgs.mcp-gateway}/bin/mcp-gateway"
          "--config"
          "${settingsFile}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        LimitLoadToSessionType = "Aqua";
        StandardOutPath = "${userhome}/Library/Logs/${agentName}.log";
        StandardErrorPath = "${userhome}/Library/Logs/${agentName}.log";
      };
    }
  ) cfg.instances;
}
