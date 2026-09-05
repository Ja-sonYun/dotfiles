{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hammerspoon.features.applicationInputSources;
  script = pkgs.replaceVars ./script.lua {
    rulesJson = builtins.toJSON cfg.rules;
  };
in
{
  options.services.hammerspoon.features.applicationInputSources = {
    enable = lib.mkEnableOption "switching input sources when applications activate";

    rules = lib.mkOption {
      type = lib.types.attrsOf lib.types.nonEmptyStr;
      default = { };
      description = "Input source IDs keyed by application name.";
    };
  };

  config.services.hammerspoon.preparedScripts = lib.mkIf cfg.enable [
    {
      name = "application-input-sources.lua";
      path = script;
    }
  ];
}
