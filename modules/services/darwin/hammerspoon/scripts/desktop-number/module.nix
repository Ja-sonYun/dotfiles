{
  config,
  lib,
  ...
}:
let
  cfg = config.services.hammerspoon.features.desktopNumber;
in
{
  options.services.hammerspoon.features.desktopNumber.enable =
    lib.mkEnableOption "the focused display's relative desktop number in the menu bar";

  config.services.hammerspoon.preparedScripts = lib.mkIf cfg.enable [
    {
      name = "desktop-number.lua";
      path = ./script.lua;
    }
  ];
}
