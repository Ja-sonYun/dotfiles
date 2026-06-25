{
  config,
  pkgs,
  infraSrc,
  userhome,
  ...
}:
let
  atticConfig = pkgs.writeTextDir "attic/config.toml" ''
    default-server = "attic"

    [servers.attic]
    endpoint = "https://ncc.test0.zip/"
    token-file = "${config.age.secrets."nix-cache-upload-token".path}"
  '';
in
{
  nix.enable = true;
  age.secrets."nix-cache-netrc" = {
    file = "${infraSrc}/services/linode-server/nix/secrets/nix-cache.netrc.age";
    path = "${userhome}/.config/nix/nix-cache.netrc";
    mode = "0600";
  };
  age.secrets."nix-cache-upload-token".file =
    "${infraSrc}/services/linode-server/nix/secrets/attic-upload-token.age";

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

  # Auto upgrade nix package and the daemon service.
  nix.package = pkgs.nix;

  home.packages = [
    pkgs.attic-client
  ];

  systemd.user.services.attic-cache-upload = {
    Unit.Description = "Watch the Nix store and upload new paths to Attic";

    Service = {
      Environment = "XDG_CONFIG_HOME=${atticConfig}";
      ExecStart = "${pkgs.attic-client}/bin/attic watch-store --jobs 5 default";
      Restart = "always";
      RestartSec = "10s";
    };

    Install.WantedBy = [ "default.target" ];
  };
}
