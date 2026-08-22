{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.yabai-indicator;
in
{
  options.services.yabai-indicator = {
    enable = lib.mkEnableOption "YabaiIndicator";

    package = lib.mkPackageOption pkgs "yabai-indicator" { };
  };

  config = lib.mkIf cfg.enable {
    home.file."Applications/YabaiIndicator.app".source =
      "${cfg.package}/Applications/YabaiIndicator.app";

    launchd.agents.yabai-indicator = {
      enable = true;
      config = {
        ProgramArguments = [
          "${cfg.package}/Applications/YabaiIndicator.app/Contents/MacOS/YabaiIndicator"
        ];
        RunAtLoad = true;
        KeepAlive = false;
      };
    };
  };
}
