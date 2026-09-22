{
  config,
  lib,
  username,
  ...
}:
let
  cfg = config.services.codeSigning;
  targetType = import ./target-type.nix { inherit lib; };
  hasTargets = cfg.targets != { };
  targetsHaveIdentities = lib.all (target: target.identity != null || cfg.defaultIdentity != null) (
    lib.attrValues cfg.targets
  );
  resolvedTargets = lib.mapAttrs (
    _: target:
    target
    // {
      identity = if target.identity != null then target.identity else cfg.defaultIdentity;
    }
  ) cfg.targets;
in
{
  options.services.codeSigning = {
    defaultIdentity = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Default Keychain identity used to sign configured targets.";
    };

    targets = lib.mkOption {
      type = lib.types.attrsOf targetType;
      default = { };
      description = "Files and application bundles installed as signed copies.";
    };
  };

  config = lib.mkIf hasTargets {
    assertions = [
      {
        assertion = targetsHaveIdentities;
        message = "Every services.codeSigning target requires an identity or defaultIdentity.";
      }
    ];

    home-manager.users.${username}.services.codeSigning.targets =
      lib.mkIf targetsHaveIdentities resolvedTargets;
  };
}
