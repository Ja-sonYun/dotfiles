{
  config,
  pkgs,
  infraSrc,
  userhome,
  ...
}:
{
  age.secrets."nix-cache-netrc" = {
    file = "${infraSrc}/services/linode-server/nix/secrets/nix-cache.netrc.age";
    path = "${userhome}/.config/nix/nix-cache.netrc";
    mode = "0600";
  };
  age.secrets."nix-cache-upload-token".file =
    "${infraSrc}/services/linode-server/nix/secrets/attic-upload-token.age";

  nix = {
    enable = true;

    # Auto upgrade nix package and the daemon service.
    package = pkgs.nix;

    settings = {
      # enable flakes globally
      experimental-features = [
        "nix-command"
        "flakes"
        "impure-derivations"
        "ca-derivations"
      ];

      trusted-users = [
        "root"
        "jason"
      ];

      # Use the official cache together with community cache
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
        "https://ncc.test0.zip/default"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "default:MJf11Ntg4Dr0YvUTkfUber/x+Kf4zQQsjupEC67ebfo="
      ];
      builders-use-substitutes = true;
      netrc-file = config.age.secrets."nix-cache-netrc".path;
    };
  };
}
