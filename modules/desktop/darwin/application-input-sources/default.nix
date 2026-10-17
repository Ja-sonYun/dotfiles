{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.applicationInputSources;
  script = pkgs.replaceVars ./script.lua {
    configurationJson = builtins.toJSON (
      {
        rules = lib.concatMapAttrs (source: apps: lib.genAttrs apps (_: source)) cfg.rules;
      }
      // lib.optionalAttrs (cfg.defaultSource != null) {
        inherit (cfg) defaultSource;
      }
    );
  };
in
{
  options.services.applicationInputSources = {
    enable = lib.mkEnableOption "per-application input sources";

    rules = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.nonEmptyStr);
      default = { };
      description = "Application names grouped by input source ID.";
    };

    defaultSource = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Input source ID for applications without a rule; null leaves them unchanged.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.hammerspoon.enable;
        message = "services.applicationInputSources requires services.hammerspoon.enable.";
      }
    ];
    services.hammerspoon = {
      enable = lib.mkDefault true;
      scripts = [
        {
          name = "application-input-sources.lua";
          path = script;
        }
      ];
    };
  };
}
