{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.sessionActions;
  enabled = cfg.onLock.enable || cfg.onBattery.enable;
  actionOptions = {
    quitApps = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      description = "Applications to quit.";
    };
    wallpaper = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      example = "Valley";
      description = "Downloaded wallpaper name without .heic; null keeps current.";
    };
  };
in
{
  options.services.sessionActions = {
    onLock = actionOptions // {
      enable = lib.mkEnableOption "screen-lock actions";
      muteMicrophone = lib.mkEnableOption "microphone muting on screen lock";
      muteAudio = lib.mkEnableOption "audio muting on screen lock";
    };
    onBattery = actionOptions // {
      enable = lib.mkEnableOption "power-disconnect actions";
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = config.services.hammerspoon.enable;
        message = "services.sessionActions requires services.hammerspoon.enable.";
      }
    ];
    services.hammerspoon = {
      enable = lib.mkDefault true;
      scripts = [
        {
          name = "shared-actions.lua";
          path = ./shared-actions.lua;
        }
      ]
      ++ lib.optionals cfg.onLock.enable [
        {
          name = "on-lock.lua";
          path = pkgs.replaceVars ./on-lock.lua {
            muteMicrophone = lib.boolToString cfg.onLock.muteMicrophone;
            muteAudio = lib.boolToString cfg.onLock.muteAudio;
            quitAppsJson = builtins.toJSON cfg.onLock.quitApps;
            wallpaperJson = builtins.toJSON (if cfg.onLock.wallpaper == null then "" else cfg.onLock.wallpaper);
          };
        }
      ]
      ++ lib.optionals cfg.onBattery.enable [
        {
          name = "on-battery.lua";
          path = pkgs.replaceVars ./on-battery.lua {
            quitAppsJson = builtins.toJSON cfg.onBattery.quitApps;
            wallpaperJson = builtins.toJSON (
              if cfg.onBattery.wallpaper == null then "" else cfg.onBattery.wallpaper
            );
          };
        }
      ];
    };
  };
}
