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

        ai_source = {
          type = "string";
          label = "AI Source";
        };
        ai_source_id = {
          type = "string";
          label = "AI Source ID";
        };
        ai_source_url = {
          type = "string";
          label = "AI Source URL";
        };
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
