{
  config,
  lib,
  pkgs,
  username,
  userhome,
  ...
}:
let
  cfg = config.services.apple-reminders;
  app = "${userhome}/Applications/RemCTL Capability Host.app";
  socket = "${userhome}/Library/Application Support/RemCTL/capability-host.sock";
  runtime = pkgs.remctl.runtimePath;
in
{
  options.services.apple-reminders = {
    enable = lib.mkEnableOption "Apple Reminders HTTP MCP; false unloads its agents and removes managed runtime files";
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Runtime HTTP authentication token file; required when enabled.";
    };
  };
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.tokenFile != null;
          message = "Apple Reminders requires services.apple-reminders.tokenFile.";
        }
      ];
      services.codeSigning.targets.apple-reminders = {
        source = "${pkgs.remctl}/Applications/RemCTL Capability Host.app";
        target = app;
        deep = true;
        restartLaunchAgent = "net.macstories.remctl.capability-host";
      };
      system.activationScripts.postActivation.text = ''
        if [ ! -d ${lib.escapeShellArg runtime} ]; then
          /bin/mkdir -p /Library/RemCTL/Python
          /usr/bin/ditto ${pkgs.remctl.runtime} ${lib.escapeShellArg "${runtime}.new"}
          /usr/sbin/chown -R root:wheel ${lib.escapeShellArg "${runtime}.new"}
          /bin/chmod -R go-w ${lib.escapeShellArg "${runtime}.new"}
          /usr/bin/touch ${lib.escapeShellArg "${runtime}.new/.nix-managed"}
          /bin/mv ${lib.escapeShellArg "${runtime}.new"} ${lib.escapeShellArg runtime}
        fi
      '';
      home-manager.users.${username} = { lib, ... }: {
        home.packages = [ pkgs.remctl ];
        home.activation.configureAppleReminders =
          lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "installSignedTargets" ]
            ''
              run /bin/mkdir -p ${lib.escapeShellArg "${userhome}/Library/Application Support/RemCTL"}
              run ${pkgs.python3}/bin/python3 ${./http-config.py} "${cfg.tokenFile}" ${lib.escapeShellArg "${userhome}/.config/remctl/mcp-http.json"}
            '';
        launchd.agents = {
          apple-reminders-host = {
            enable = true;
            config = {
              Label = "net.macstories.remctl.capability-host";
              ProgramArguments = [
                "${app}/Contents/MacOS/RemCTL Capability Host"
                "--run-capability-host"
                "--socket"
                socket
              ];
              RunAtLoad = true;
              KeepAlive = true;
              LimitLoadToSessionType = "Aqua";
            };
          };
          apple-reminders = {
            enable = true;
            config = {
              Label = "net.macstories.remctl.mcp-http";
              ProgramArguments = [
                "${pkgs.remctl}/bin/remctl"
                "mcp"
                "serve"
                "--http"
                "--port"
                "7362"
              ];
              EnvironmentVariables = {
                REMCTL_CAPABILITY_HOST_APP = app;
                REMCTL_CAPABILITY_HOST_SOCKET = socket;
              };
              RunAtLoad = true;
              KeepAlive = true;
              LimitLoadToSessionType = "Aqua";
              StandardOutPath = "${userhome}/Library/Logs/apple-reminders.log";
              StandardErrorPath = "${userhome}/Library/Logs/apple-reminders.log";
            };
          };
        };
      };
    })
    (lib.mkIf (!cfg.enable) {
      system.activationScripts.postActivation.text = ''
        if [ -f ${lib.escapeShellArg "${runtime}/.nix-managed"} ]; then
          user_id=$(/usr/bin/id -u ${lib.escapeShellArg username})
          for label in net.macstories.remctl.mcp-http net.macstories.remctl.capability-host; do
            if /bin/launchctl print "gui/$user_id/$label" >/dev/null 2>&1; then
              /bin/launchctl bootout "gui/$user_id/$label" || exit 1
            fi
          done
          /bin/rm -rf ${lib.escapeShellArg runtime}
        fi
      '';
      home-manager.users.${username} = { lib, ... }: {
        home.activation.removeAppleReminders = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
          if [ -f ${lib.escapeShellArg "${app}.source"} ]; then
            run /bin/rm -rf ${lib.escapeShellArg app}
            run /bin/rm -f ${lib.escapeShellArg "${app}.source"} ${lib.escapeShellArg "${userhome}/.config/remctl/mcp-http.json"}
          fi
        '';
      };
    })
  ];
}
