{
  config,
  lib,
  pkgs,
  userhome,
  username,
  ...
}:
let
  cfg = config.services.yabai.extensions.controller;
in
{
  options.services.yabai.extensions.controller = {
    enable = lib.mkEnableOption "the resident yabai command controller" // {
      default = config.services.yabai.enable;
    };
    socketPath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${userhome}/Library/Caches/yabai-controller/control.sock";
      description = "User-owned controller socket for Hammerspoon keybindings.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.yabai.enable;
        message = "services.yabai.extensions.controller requires services.yabai.enable.";
      }
      {
        assertion = config.services.hammerspoon.enable;
        message = "services.yabai.extensions.controller requires services.hammerspoon.enable.";
      }
    ];

    services.hammerspoon.enable = lib.mkDefault true;

    launchd.user.agents.yabai-controller = {
      startupGuard.enable = true;
      serviceConfig = {
        ProgramArguments = [
          "${pkgs.yabai-controller}/bin/yabai-controller"
          "--socket"
          cfg.socketPath
          "--yabai-socket"
          "/tmp/yabai_${username}.socket"
        ];
        RunAtLoad = true;
        KeepAlive.SuccessfulExit = false;
        ProcessType = "Interactive";
        Umask = 63;
        ThrottleInterval = 5;
        StandardErrorPath = "${userhome}/Library/Logs/yabai-controller.log";
      };
    };
  };
}
