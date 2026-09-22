{
  config,
  lib,
  ...
}:
{
  options.services.autostartApps = lib.mkOption {
    type = lib.types.listOf lib.types.nonEmptyStr;
    default = [ ];
    description = "Application names to launch at macOS GUI login.";
  };

  config.launchd.agents = builtins.listToAttrs (
    map (app: {
      name = "autostart-${app}";
      value = {
        enable = true;
        config = {
          ProgramArguments = [
            "/usr/bin/open"
            "-a"
            app
          ];
          RunAtLoad = true;
          LimitLoadToSessionType = "Aqua";
        };
      };
    }) config.services.autostartApps
  );
}
