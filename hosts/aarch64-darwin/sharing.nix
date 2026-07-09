{
  lib,
  username,
  ...
}:

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

    # Remote Management conflicts with Screen Sharing; keep it off.
    /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
      -deactivate -stop -quiet >/dev/null 2>&1 || true

    enable_system_service \
      system/com.apple.screensharing \
      /System/Library/LaunchDaemons/com.apple.screensharing.plist
  '';
}
