{
  hasTag,
  hostname,
  infraSrc,
  lib,
  ...
}:
{
  imports =
    lib.optionals (hasTag "gui") [
      ./yabai
      ./skhd
    ]
    ++ lib.optionals (hasTag "server") [
      ./sharing.nix
    ]
    ++ lib.optionals (hostname == "Jays-MacBook-Pro-Server") [
      (infraSrc + "/services/Jays-MacBook-Pro-Server")
    ];

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

      clean-notifications = {
        displayName = "Clean Notifications";
        icon = ./icons/clean-notifications.svg;
        command = [
          "/usr/bin/osascript"
          "${./scripts/dismiss-notifications}"
        ];
        appleEventsUsageDescription = "Clean Notifications uses System Events to dismiss visible notifications.";
      };
    };
  };
}
