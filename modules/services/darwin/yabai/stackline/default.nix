{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.yabai.stackline;
  script = pkgs.replaceVars ./script.lua {
    sourceDirectory = ./source;
    yabai = "${config.services.yabai.package}/bin/yabai";
  };
in
{
  options.services.yabai.stackline.enable = lib.mkEnableOption "minimal yabai stack indicators";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.yabai.enable;
        message = "services.yabai.stackline requires services.yabai.enable.";
      }
      {
        assertion = config.services.hammerspoon.enable;
        message = "services.yabai.stackline requires services.hammerspoon.enable.";
      }
    ];

    services.hammerspoon.scripts = [
      {
        name = "stackline-bootstrap.lua";
        path = script;
      }
    ];
  };
}
