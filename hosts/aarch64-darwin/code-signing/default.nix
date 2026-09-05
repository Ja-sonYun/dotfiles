{
  hostname,
  lib,
  ...
}:

{
  services.codeSigning.defaultIdentity =
    lib.mkIf (hostname != "Jays-MacBook-Pro-Server") "nix-local-code-signing";

  services.codeSigning.targets =
    lib.mkIf (hostname == "Jays-MacBook-Pro-Server") (lib.mkForce { });
}
