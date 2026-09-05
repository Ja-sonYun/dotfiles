{ lib }:
lib.types.submodule {
  options = {
    source = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Store path copied before signing.";
    };

    target = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Stable path where the signed copy is installed.";
    };

    identity = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Code Signing identity overriding the service default.";
    };

    restartLaunchAgent = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "User launch agent restarted after the signed copy changes.";
    };
  };
}
