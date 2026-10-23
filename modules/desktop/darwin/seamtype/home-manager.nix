{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.seamtype;
  json = pkgs.formats.json { };
  disableInputSource = pkgs.stdenv.mkDerivation {
    name = "seamtype-disable-input-source";
    dontUnpack = true;
    buildInputs = [ pkgs.apple-sdk_15 ];
    buildPhase = ''
      $CC -std=c11 -Wall -Wextra ${./disable-input-source.c} \
        -framework Carbon -o seamtype-disable-input-source
    '';
    installPhase = ''
      install -Dm755 seamtype-disable-input-source "$out/bin/seamtype-disable-input-source"
    '';
  };
  configuration = json.generate "seamtype-activation.json" (
    {
      inherit (cfg) enable;
      bundle = "${config.home.homeDirectory}/Library/Input Methods/Seamtype.app";
    }
    // lib.optionalAttrs (cfg.enable == true) {
      source = "${cfg.package}/Applications/Seamtype.app";
      directory = "${config.home.homeDirectory}/Library/Application Support/Seamtype";
      inherit (cfg) settings appDefaults holdSpace;
    }
  );
  activation = pkgs.writeShellApplication {
    name = "seamtype-activation";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.macism
      disableInputSource
    ]
    ++ lib.optional (cfg.enable == true) pkgs.rsync;
    text = builtins.readFile ./activate.sh;
  };
in
{
  imports = [ ./tmux.nix ];

  options.services.seamtype = {
    enable = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Manage Seamtype; null leaves it unmanaged. False selects ABC, disables
        Seamtype and removes the managed user bundle while retaining settings
        and learning data. Previously disabled input sources are not restored.
      '';
    };
    package = lib.mkPackageOption pkgs "seamtype" { };
    holdSpace = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Set holdSpace for every app on activation; null preserves existing app settings.";
    };
    settings = lib.mkOption {
      type = lib.types.attrsOf json.type;
      default = { };
      description = "Global settings merged on activation; other keys are preserved.";
    };
    appDefaults = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf json.type);
      default = { };
      description = "App settings used only for missing keys, preserving later UI changes.";
    };
  };

  config = lib.mkIf (cfg.enable != null) {
    home.activation.seamtype = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${activation}/bin/seamtype-activation ${configuration}
    '';
  };
}
