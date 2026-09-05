{ config, lib, ... }:
let
  cfg = config.services.hammerspoon.features.muteMicrophoneOnLock;
in
{
  options.services.hammerspoon.features.muteMicrophoneOnLock.enable =
    lib.mkEnableOption "muting the default microphone when the screen locks";

  config.services.hammerspoon.preparedScripts = lib.mkIf cfg.enable [
    {
      name = "mute-microphone-on-lock.lua";
      path = ./script.lua;
    }
  ];
}
