{
  agenix-secrets,
  pkgs,
  userhome,
  ...
}:
{
  imports = [ "${agenix-secrets}/modules/taskwarrior" ];

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

    ai.enable = true;
  };
}
