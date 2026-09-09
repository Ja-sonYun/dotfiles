{ config, lib, ... }:
let
  cfg = config.services.hammerspoon.features;
  actionOptions = {
    quitApps = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      description = "Application names to quit when the event occurs.";
    };

    wallpaper = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      example = "Valley";
      description = "Downloaded macOS wallpaper name, without .heic, to apply after requesting application quits. Null leaves the wallpaper unchanged.";
    };
  };
in
{
  options.services.hammerspoon.features = lib.genAttrs [
    "onLock"
    "onBattery"
  ] (_: actionOptions);

  config.services.hammerspoon.preparedScripts = lib.mkIf (cfg.onLock.enable || cfg.onBattery.enable) [
    {
      name = "shared-actions.lua";
      path = ./script.lua;
    }
  ];
}
