{
  config,
  lib,
  pkgs,
  username,
  userhome,
  ...
}:
let
  cfg = config.services.apple-calendar;
  target = "${userhome}/.local/libexec/apple-calendar/ical";
in
{
  options.services.apple-calendar.enable = lib.mkEnableOption "Apple Calendar HTTP MCP; false unloads the server and removes its signed executable";
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      services.codeSigning.targets.apple-calendar = {
        source = "${pkgs.ical}/bin/ical";
        inherit target;
        restartLaunchAgent = "org.nix-community.home.apple-calendar";
      };
      home-manager.users.${username} = {
        home.packages = [ (pkgs.writeShellScriptBin "ical" ''exec ${lib.escapeShellArg target} "$@"'') ];
        launchd.agents.apple-calendar = {
          enable = true;
          config = {
            ProgramArguments = [ "${pkgs.calendar-mcp}/bin/calendar-mcp" ];
            EnvironmentVariables.CALENDAR_EXECUTABLE = target;
            RunAtLoad = true;
            KeepAlive = true;
            LimitLoadToSessionType = "Aqua";
            StandardOutPath = "${userhome}/Library/Logs/apple-calendar.log";
            StandardErrorPath = "${userhome}/Library/Logs/apple-calendar.log";
          };
        };
      };
    })
    (lib.mkIf (!cfg.enable) {
      home-manager.users.${username} = { lib, ... }: {
        home.activation.removeAppleCalendar = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
          if [ -f ${lib.escapeShellArg "${target}.source"} ]; then
            run /bin/rm -f ${lib.escapeShellArg target} ${lib.escapeShellArg "${target}.source"}
          fi
        '';
      };
    })
  ];
}
