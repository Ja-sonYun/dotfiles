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
      PubkeyAuthentication yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitEmptyPasswords no
    '';
  };

  users.users.${username}.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDAgN11TCcYXznIXjH0WbLhRA1ae2OB3+tr1ULbxXCg4OlVPja7BgKp9qgwfPiUna12Grb3VeH+82d45R2xnDIRYIwoq6LFHNSGt5p0MGY4E2iToUlu/5ZS0jH32Lt6xT1OK4QmcK7q0NH2Ed0Cvc1En880MXF21nj2t5h0Fqe4gLPmJxy6Ss3IczmlDO3gBbwhFidvLmTp6VxnUq4HUT4G6LpwgKKM24fZR0ji1vbh6eKcAbgcKJRV4b/+LNO1nSjw1bbuzsdtjfRYNgW7O9U7eQR4q8yaZE1uA7MocT5bUvuFVifQ4zW7HPBsWS3fCPB57rUnt1m+ud4MNs1GpVPKBfAniHrbxuRYJlKecQbTv+h5d/erEY72vwqC4ySMv6V0FhkIa7dNRtVfk55RUzvUgZqbr87YAQ71xqpNBikxoH3BrAYAHW+fU6q8xNJfTCCCO4Uqu+xHHvKKcFX7FAV59vEaeu+PfAjaFT9Ls0m/XzwcEQotPwWTIR5P434yW4c= jasony@Jasons-MacBook-Pro.local"
  ];

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
