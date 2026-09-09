{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hammerspoon.features.onBattery;
  script = pkgs.replaceVars ./script.lua {
    quitAppsJson = builtins.toJSON cfg.quitApps;
    wallpaperJson = builtins.toJSON (if cfg.wallpaper == null then "" else cfg.wallpaper);
  };
in
{
  options.services.hammerspoon.features.onBattery.enable =
    lib.mkEnableOption "running actions when external power is disconnected";

  config.services.hammerspoon.preparedScripts = lib.mkIf cfg.enable [
    {
      name = "on-battery.lua";
      path = script;
    }
  ];
}
