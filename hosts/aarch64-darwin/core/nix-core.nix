{
  lib,
  nixpkgs-stable,
  pkgs,
  ...
}:
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

    # substituers that will be considered before the official ones(https://cache.nixos.org)
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      # "https://ncc.test0.zip/default"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      # "default:MJf11Ntg4Dr0YvUTkfUber/x+Kf4zQQsjupEC67ebfo="
    ];
    builders-use-substitutes = true;
    # netrc-file = config.age.secrets."nix-cache-netrc".path;
  };

  # Auto upgrade nix package and the daemon service.
  nix.package = pkgs.nix;

  environment.systemPackages = [
    pkgs.attic-client
  ];

  # launchd.daemons.attic-cache-upload = {
  #   environment.XDG_CONFIG_HOME = "${atticConfig}";
  #   command = "${pkgs.attic-client}/bin/attic watch-store --jobs 5 default";
  #   serviceConfig = {
  #     KeepAlive.PathState.${config.age.secrets."nix-cache-upload-token".path} = true;
  #     StandardOutPath = "/var/log/attic-cache-upload.log";
  #     StandardErrorPath = "/var/log/attic-cache-upload.err.log";
  #   };
  # };

  nix.linux-builder = {
    enable = true;
    package = nixpkgs-stable.legacyPackages.${pkgs.system}.darwin.linux-builder;
    systems = [ "aarch64-linux" ];
    config = {
      virtualisation = {
        cores = 4;
        darwin-builder.memorySize = 8192;
      };
    };
  };

  # On-demand: don't keep the QEMU builder VM running when idle. The Makefile
  # starts it before a build and tears it down after deploy.
  launchd.daemons.linux-builder.serviceConfig = {
    RunAtLoad = lib.mkForce false;
    KeepAlive = lib.mkForce false;
  };
}
