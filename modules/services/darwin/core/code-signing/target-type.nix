{ lib }:
lib.types.submodule {
  options = {
    source = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Source store path.";
    };

    target = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Signed copy destination.";
    };

    identity = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Signing identity override.";
    };

    restartLaunchAgent = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "LaunchAgent to restart after signing changes.";
    };
  };
}
