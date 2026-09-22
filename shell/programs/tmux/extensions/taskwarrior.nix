{ config, lib, ... }:
lib.mkIf
  (
    config.programs.taskwarrior.enable
    && config.programs.tmux.enable
    && config.programs.tmux-menu.enable
  )
  {
    programs.tmux-menu.menus.menu.items = lib.mkOrder 300 [
      {
        menu = {
          name = "taskwarrior";
          shortcut = "t";
          command = "cd ~/ && taskwarrior-tui";
          session = true;
          sessionName = "taskwarrior-tui";
          keyTable =
            if config.programs.tmux.extensions.popup.enable then "popup-locked-root" else "common-root";
          environment.CTRL_C_AS_CLOSE = "1";
          position = {
            w = "60%";
            h = "70%";
          };
        };
      }
    ];
  }
