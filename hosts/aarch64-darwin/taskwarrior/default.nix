{
  lib,
  pkgs,
  userhome,
  ...
}:
{
  home.packages = [ pkgs.taskwarrior-tui ];

  programs.taskwarrior = {
    enable = true;
    package = pkgs.taskwarrior3;
    dataLocation = "${userhome}/.task";

    config = {
      news.version = pkgs.taskwarrior3.version;
      confirmation = false;

      uda = {
        taskwarrior-tui.task-report.next.filter = "status:pending -WAITING";
      };

      color = {
        project.Todos = "yellow";
        tag = {
          xteam = "yellow";
          urgent = "bold red on gray";
          waiting = "blue";
        };
      };
    };
  };

  programs.tmux-menu.menus.menu.items = lib.mkOrder 300 [
    {
      menu = {
        name = "taskwarrior";
        shortcut = "t";
        command = "cd ~/ && taskwarrior-tui";
        session = true;
        sessionName = "taskwarrior-tui";
        keyTable = "popup-locked-root";
        environment.CTRL_C_AS_CLOSE = "1";
        position = {
          w = "60%";
          h = "70%";
        };
      };
    }
  ];
}
