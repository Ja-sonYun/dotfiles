{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.menubar;
  managed = cfg.hideSpotlight != null || cfg.weather.enable != null;
  user = lib.escapeShellArg config.system.primaryUser;
  applyMenubar = pkgs.writeShellScript "apply-menubar" ''
    set -euo pipefail

    uid=$(/usr/bin/id -u -- ${user})
    ${lib.optionalString (cfg.hideSpotlight != null) ''
      /bin/launchctl asuser "$uid" /usr/bin/sudo --user=${user} -- \
        /usr/bin/defaults -currentHost write com.apple.Spotlight MenuItemHidden -int ${
          if cfg.hideSpotlight then "1" else "0"
        }
    ''}
    ${lib.optionalString (cfg.weather.enable == false) ''
      if /usr/bin/pgrep -u "$uid" -x WeatherMenu >/dev/null; then
        /usr/bin/killall -u ${user} WeatherMenu
      fi
    ''}

    if ! /bin/launchctl print "gui/$uid" >/dev/null 2>&1; then
      printf '%s\n' ${lib.escapeShellArg "Skipping menu extras: no GUI session for ${config.system.primaryUser}."} >&2
      exit 0
    fi

    ${lib.optionalString (cfg.weather.enable == true) ''
      weather_app=/System/Applications/Weather.app/Contents/Library/LoginItems/WeatherMenu.app
      if [ -d "$weather_app" ]; then
        /bin/launchctl asuser "$uid" /usr/bin/sudo --user=${user} -- \
          /usr/bin/open -gj "$weather_app"
      fi
    ''}
    /usr/bin/killall -u ${user} ControlCenter 2>/dev/null || true
    /usr/bin/killall -u ${user} SystemUIServer 2>/dev/null || true
  '';
in
{
  imports = [ ./desktop-number ];

  options.services.menubar = {
    hideSpotlight = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Hide Spotlight in the menu bar; false shows it and null leaves it unmanaged.";
    };
    weather.enable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Start WeatherMenu at activation; false stops it for the primary user and null leaves it unmanaged.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.hideSpotlight != null) {
      system.defaults.CustomUserPreferences."com.apple.Spotlight"."NSStatusItem VisibleCC Item-0" =
        if cfg.hideSpotlight then 0 else 1;
    })
    (lib.mkIf managed {
      system.requiresPrimaryUser = [ "services.menubar" ];
      system.activationScripts.postActivation.text = lib.mkOrder 1600 ''
        ${applyMenubar} || exit $?
      '';
    })
  ];
}
