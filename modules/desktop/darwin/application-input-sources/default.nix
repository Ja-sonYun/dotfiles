{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.applicationInputSources;
  script = pkgs.replaceVars ./script.lua {
    rulesJson = builtins.toJSON cfg.rules;
  };
in
{
  options.services.applicationInputSources = {
    enable = lib.mkEnableOption "switching input sources when applications activate";

    rules = lib.mkOption {
      type = lib.types.attrsOf lib.types.nonEmptyStr;
      default = { };
      description = "Input source IDs keyed by application name.";
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
