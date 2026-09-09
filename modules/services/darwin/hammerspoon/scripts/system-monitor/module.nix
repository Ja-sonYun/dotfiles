{ config, lib, ... }:
let
  cfg = config.services.hammerspoon.features.systemMonitor;
in
{
  options.services.hammerspoon.features.systemMonitor.enable =
    lib.mkEnableOption "CPU, memory, and storage usage in the menu bar";

  config.services.hammerspoon.preparedScripts = lib.mkIf cfg.enable [
    {
      name = "system-monitor.lua";
      path = ./script.lua;
    }
  ];
}
