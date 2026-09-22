{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.atticCacheUpload;
  atticConfig = pkgs.writeTextDir "attic/config.toml" ''
    default-server = "attic"

    [servers.attic]
    endpoint = ${builtins.toJSON cfg.endpoint}
    token-file = ${builtins.toJSON cfg.tokenFile}
  '';
in
{
  options.services.atticCacheUpload = {
    enable = lib.mkEnableOption "uploading new Nix store paths to Attic";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.attic-client;
      description = "Attic client package.";
    };
    endpoint = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Attic server endpoint.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Runtime path to the upload token file.";
    };
    cache = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "default";
      description = "Cache receiving new store paths.";
    };
    jobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Number of concurrent uploads.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    systemd.user.services.attic-cache-upload = {
      Unit.Description = "Watch the Nix store and upload new paths to Attic";
      Service = {
        Environment = "XDG_CONFIG_HOME=${atticConfig}";
        ExecStart = lib.escapeShellArgs [
          "${cfg.package}/bin/attic"
          "watch-store"
          "--jobs"
          (toString cfg.jobs)
          cfg.cache
        ];
        Restart = "always";
        RestartSec = "10s";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
