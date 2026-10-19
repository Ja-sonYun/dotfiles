{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.yabai.extensions.desktopIndicator;
  script = pkgs.replaceVars ./script.lua {
    yabai = "${config.services.yabai.package}/bin/yabai";
    controllerSocket =
      if
        config.services.yabai.extensions.controller.enable && config.services.hammerspoon.keybindings != { }
      then
        config.services.yabai.extensions.controller.socketPath
      else
        "";
  };
in
{
  options.services.yabai.extensions.desktopIndicator.enable =
    lib.mkEnableOption "per-display yabai desktop indicators";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.yabai.enable;
        message = "services.yabai.extensions.desktopIndicator requires services.yabai.enable.";
      }
      {
        assertion = config.services.hammerspoon.enable;
        message = "services.yabai.extensions.desktopIndicator requires services.hammerspoon.enable.";
      }
    ];

    services.hammerspoon.scripts = [
      {
        name = "yabai-desktop-indicator.lua";
        path = script;
      }
    ];
  };
}
