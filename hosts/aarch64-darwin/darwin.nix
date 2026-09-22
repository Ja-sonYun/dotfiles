{
  hasTag,
  hostname,
  infraSrc,
  lib,
  ...
}:
{
  imports = [
    ./system/nix.nix
    ./system/macos.nix
    ./system/users.nix
    ./system/shell.nix
    ./system/homebrew.nix
    ./desktop/display.nix
    ./desktop/menubar.nix
    ./desktop/spotlight
    ./services/docker-compose.nix
    ./services/sharing.nix
  ]
  ++ lib.optionals (hasTag "gui") [
    ./desktop/application-input-sources.nix
    ./desktop/session-actions.nix
    ./services/activity-history.nix
    ./services/core/code-signing.nix
    ./services/core/hammerspoon.nix
    ./services/yabai
    ./services/skhd.nix
  ]
  ++ lib.optionals (hasTag "meeting") [
    ./services/meeting-recorder.nix
  ]
  ++ lib.optionals (hostname == "Jays-MacBook-Pro-Server") [
    (infraSrc + "/services/Jays-MacBook-Pro-Server")
  ];
}
