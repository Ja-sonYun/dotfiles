{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hammerspoon.features.onLock;
  script = pkgs.replaceVars ./script.lua {
    muteMicrophone = lib.boolToString cfg.muteMicrophone;
    muteAudio = lib.boolToString cfg.muteAudio;
    quitAppsJson = builtins.toJSON cfg.quitApps;
    wallpaperJson = builtins.toJSON (if cfg.wallpaper == null then "" else cfg.wallpaper);
  };
in
{
  options.services.hammerspoon.features.onLock = {
    enable = lib.mkEnableOption "running actions when the screen locks";
    muteMicrophone = lib.mkEnableOption "muting the default microphone when the screen locks";
    muteAudio = lib.mkEnableOption "muting the default audio output when the screen locks";
  };

  config.services.hammerspoon.preparedScripts = lib.mkIf cfg.enable [
    {
      name = "on-lock.lua";
      path = script;
    }
  ];
}
