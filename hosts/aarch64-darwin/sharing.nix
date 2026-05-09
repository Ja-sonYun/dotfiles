{ lib
, username
, ...
}:

let
  remoteManagementKickstart =
    "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart";
in
{
  services.openssh = {
    enable = true;
    extraConfig = ''
      AllowUsers ${username}
    '';
  };

  system.defaults.CustomUserPreferences = {
    "com.apple.amp.mediasharingd" = {
      "public-sharing-enabled" = true;
    };
  };

  system.activationScripts.postActivation.text = lib.mkAfter ''
    set -euo pipefail

    user_name=${lib.escapeShellArg username}

    enable_system_service() {
      local target="$1"
      local plist="$2"

      /bin/launchctl enable "$target" >/dev/null 2>&1 || true
      /bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || true
      /bin/launchctl kickstart -k "$target" >/dev/null 2>&1 || true
    }

    enable_system_service \
      system/com.apple.smbd \
      /System/Library/LaunchDaemons/com.apple.smbd.plist

    enable_system_service \
      system/com.apple.AEServer \
      /System/Library/LaunchDaemons/com.apple.eppc.plist

    /usr/sbin/cupsctl --share-printers

    ${lib.escapeShellArg remoteManagementKickstart} \
      -activate \
      -configure -allowAccessFor -specifiedUsers \
      -users "$user_name" -access -on -privs -all \
      -restart -agent \
      -quiet
  '';
}
