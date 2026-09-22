{ lib, writeShellScriptBin }:
(writeShellScriptBin "dismiss-notifications" ''
  exec /usr/bin/osascript ${./dismiss-notifications.applescript} "$@"
'').overrideAttrs
  {
    meta = {
      description = "Dismiss visible macOS notifications";
      mainProgram = "dismiss-notifications";
      platforms = lib.platforms.darwin;
    };
  }
