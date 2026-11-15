{
  config,
  lib,
  pkgs,
  username,
  userhome,
  ...
}:
let
  cfg = config.services.codex-connectors-mcp;
  start = pkgs.writeShellScript "codex-connectors-mcp-start" ''
    set -eu
    CODEX_CONNECTORS_HTTP_TOKEN="$(< ${lib.escapeShellArg cfg.tokenFile})"
    export CODEX_CONNECTORS_HTTP_TOKEN
    export CODEX_CONNECTORS_CODEX=${lib.escapeShellArg cfg.codexCommand}
    export CODEX_HOME=${lib.escapeShellArg cfg.codexHome}
    export CODEX_CONNECTORS_WRITES=ask
    unset CODEX_CONNECTORS_ALLOW
    exec ${pkgs.codex-connectors-mcp}/bin/codex-connectors-mcp --transport http --port 8787
  '';
in
{
  options.services.codex-connectors-mcp = {
    enable = lib.mkEnableOption "the internal Codex connector bridge; disabling unloads its agent and preserves Codex authentication";
    codexCommand = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Absolute path to the managed Codex profile command.";
    };
    codexHome = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Absolute home directory of the selected Codex profile.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Runtime file containing the shared HTTP bearer token.";
    };
  };
  config = {
    assertions = lib.optionals cfg.enable [
      {
        assertion = config.home-manager.users.${username}.programs.codex.enable;
        message = "Codex connector bridge requires programs.codex.enable.";
      }
      {
        assertion = lib.all (value: lib.hasPrefix "/" value) [
          cfg.codexCommand
          cfg.codexHome
          cfg.tokenFile
        ];
        message = "Codex connector bridge requires absolute codexCommand, codexHome and tokenFile paths.";
      }
    ];
    home-manager.users.${username}.launchd.agents.codex-connectors-mcp = {
      inherit (cfg) enable;
      config = lib.mkIf cfg.enable {
        ProgramArguments = [ "${start}" ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        ExitTimeOut = 20;
        LimitLoadToSessionType = "Aqua";
        StandardOutPath = "${userhome}/Library/Logs/codex-connectors-mcp.log";
        StandardErrorPath = "${userhome}/Library/Logs/codex-connectors-mcp.log";
      };
    };
  };
}
