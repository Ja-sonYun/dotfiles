{ pkgs, ... }:
{
  nix.enable = true;
  nix.settings = {
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
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    builders-use-substitutes = true;
  };

  # Auto upgrade nix package and the daemon service.
  nix.package = pkgs.nix;
}
