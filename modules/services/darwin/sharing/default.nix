{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sharing;
  managed = lib.any (feature: feature.enable != null) (builtins.attrValues cfg);
  serviceCommand =
    enabled: target: plist:
    lib.optionalString (enabled != null) ''
      ${
        if enabled then "enable" else "disable"
      }_system_service ${lib.escapeShellArg target} ${lib.escapeShellArg plist}
    '';
  applySharing = pkgs.writeShellScript "apply-sharing" ''
    set -euo pipefail

    enable_system_service() {
      local target="$1" plist="$2"
      /bin/launchctl enable "$target"
      if ! /bin/launchctl print "$target" >/dev/null 2>&1; then
        /bin/launchctl bootstrap system "$plist"
      fi
      /bin/launchctl kickstart -k "$target"
    }

    disable_system_service() {
      local target="$1"
      /bin/launchctl disable "$target"
      if /bin/launchctl print "$target" >/dev/null 2>&1; then
        /bin/launchctl bootout "$target"
      fi
    }

    ${serviceCommand cfg.fileSharing.enable "system/com.apple.smbd"
      "/System/Library/LaunchDaemons/com.apple.smbd.plist"
    }
    ${serviceCommand cfg.remoteAppleEvents.enable "system/com.apple.AEServer"
      "/System/Library/LaunchDaemons/com.apple.eppc.plist"
    }
    ${lib.optionalString (cfg.printerSharing.enable != null) ''
      /usr/sbin/cupsctl --${lib.optionalString (!cfg.printerSharing.enable) "no-"}share-printers
    ''}
    ${lib.optionalString (cfg.screenSharing.enable == true) ''
      # Remote Management must release the service before Screen Sharing starts.
      /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
        -deactivate -stop -quiet
    ''}
    ${serviceCommand cfg.screenSharing.enable "system/com.apple.screensharing"
      "/System/Library/LaunchDaemons/com.apple.screensharing.plist"
    }
  '';
in
{
  options.services.sharing =
    lib.genAttrs
      [
        "fileSharing"
        "remoteAppleEvents"
        "printerSharing"
        "screenSharing"
      ]
      (name: {
        enable = lib.mkOption {
          type = lib.types.nullOr lib.types.bool;
          default = null;
          description = "Enable ${name}; null leaves it unmanaged.";
        };
      });

  config = lib.mkIf managed {
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${applySharing} || exit $?
    '';
  };
}
