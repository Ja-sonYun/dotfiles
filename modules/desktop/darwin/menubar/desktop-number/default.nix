{
  config,
  lib,
  ...
}:
let
  cfg = config.services.menubar.desktopNumber;
in
{
  options.services.menubar.desktopNumber.enable =
    lib.mkEnableOption "the focused display's relative desktop number in the menu bar";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.hammerspoon.enable;
        message = "services.menubar.desktopNumber requires services.hammerspoon.enable.";
      }
    ];
    services.hammerspoon = {
      enable = lib.mkDefault true;
      scripts = [
        {
          name = "desktop-number.lua";
          path = ./script.lua;
        }
      ];
    };
  };
}
