{
  hasTag,
  lib,
  pkgs,
  ...
}:
{
  programs.spotlightScripts = lib.mkIf (hasTag "gui") {
    enable = true;
    bundleIdentifierPrefix = "com.jaykuroyanagi.spotlight";

    apps = {
      reset-airplay = {
        displayName = "Reset AirPlay";
        icon = ./icons/reset-airplay.svg;
        command = [
          "/bin/launchctl"
          "kickstart"
          "-k"
          "system/com.apple.AirPlayXPCHelper"
        ];
        runAsAdmin = true;
      };

      cn = {
        displayName = "cn";
        icon = ./icons/clean-notifications.svg;
        command = [
          "${pkgs.dismiss-notifications}/bin/dismiss-notifications"
        ];
        appleEventsUsageDescription = "cn uses System Events to dismiss visible notifications.";
      };
    };
  };
}
