{
  lib,
  username,
  ...
}:

let
  weatherMenuApp = "/System/Applications/Weather.app/Contents/Library/LoginItems/WeatherMenu.app";
in
{
  system = {
    defaults = {
      controlcenter = {
        AirDrop = false;
        Bluetooth = false;
        Display = false;
        NowPlaying = false;
        Sound = true;
      };

      CustomUserPreferences = {
        "com.apple.Spotlight" = {
          # Hide the Spotlight icon from the menu bar.
          "NSStatusItem VisibleCC Item-0" = 0;
        };

        "com.apple.controlcenter" = {
          # Keep standard Control Center menu bar items visible without changing their order.
          "NSStatusItem VisibleCC AirDrop" = 0;
          "NSStatusItem VisibleCC Battery" = 1;
          "NSStatusItem VisibleCC BentoBox-0" = 1;
          "NSStatusItem VisibleCC Clock" = 1;
          "NSStatusItem VisibleCC FocusModes" = 1;
          "NSStatusItem VisibleCC Sound" = 1;
          "NSStatusItem VisibleCC WiFi" = 1;
        };

        "com.apple.TextInputMenuAgent" = {
          # Keep the input source menu visible.
          "NSStatusItem VisibleCC Item-0" = 1;
        };
      };
    };

    activationScripts.postActivation.text = lib.mkAfter ''
      weatherMenuApp=${lib.escapeShellArg weatherMenuApp}

      # Hide Spotlight's menu bar item in the current host preferences.
      /bin/launchctl asuser "$(/usr/bin/id -u -- ${lib.escapeShellArg username})" \
        /usr/bin/sudo --user=${lib.escapeShellArg username} -- \
        /usr/bin/defaults -currentHost write com.apple.Spotlight MenuItemHidden -int 1

      if [ -d "$weatherMenuApp" ]; then
        # Start Apple's Weather menu extra for the current GUI user.
        /bin/launchctl asuser "$(/usr/bin/id -u -- ${lib.escapeShellArg username})" \
          /usr/bin/sudo --user=${lib.escapeShellArg username} -- \
          /usr/bin/open -gj "$weatherMenuApp"
      fi

      # Reload menu bar extras after changing visibility defaults.
      /usr/bin/killall ControlCenter || true
      /usr/bin/killall SystemUIServer || true
    '';
  };
}
