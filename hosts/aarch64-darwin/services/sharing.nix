{
  hasTag,
  lib,
  username,
  ...
}:

{
  services.openssh = {
    enable = hasTag "server";
    extraConfig = ''
      AllowUsers ${username}
      PubkeyAuthentication yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitEmptyPasswords no
    '';
  };

  users.users.${username}.openssh.authorizedKeys.keys = lib.optionals (hasTag "server") [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDAgN11TCcYXznIXjH0WbLhRA1ae2OB3+tr1ULbxXCg4OlVPja7BgKp9qgwfPiUna12Grb3VeH+82d45R2xnDIRYIwoq6LFHNSGt5p0MGY4E2iToUlu/5ZS0jH32Lt6xT1OK4QmcK7q0NH2Ed0Cvc1En880MXF21nj2t5h0Fqe4gLPmJxy6Ss3IczmlDO3gBbwhFidvLmTp6VxnUq4HUT4G6LpwgKKM24fZR0ji1vbh6eKcAbgcKJRV4b/+LNO1nSjw1bbuzsdtjfRYNgW7O9U7eQR4q8yaZE1uA7MocT5bUvuFVifQ4zW7HPBsWS3fCPB57rUnt1m+ud4MNs1GpVPKBfAniHrbxuRYJlKecQbTv+h5d/erEY72vwqC4ySMv6V0FhkIa7dNRtVfk55RUzvUgZqbr87YAQ71xqpNBikxoH3BrAYAHW+fU6q8xNJfTCCCO4Uqu+xHHvKKcFX7FAV59vEaeu+PfAjaFT9Ls0m/XzwcEQotPwWTIR5P434yW4c= jasony@Jasons-MacBook-Pro.local"
  ];

  system.defaults.CustomUserPreferences = {
    "com.apple.amp.mediasharingd" = {
      "public-sharing-enabled" = hasTag "server";
    };
  };

  services.sharing = {
    fileSharing.enable = hasTag "server";
    remoteAppleEvents.enable = hasTag "server";
    printerSharing.enable = hasTag "server";
    screenSharing.enable = hasTag "server";
  };
}
