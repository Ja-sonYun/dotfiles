{
  pkgs,
  userhome,
  ...
}:
{
  home.file."taskrc" = {
    target = ".taskrc";
    text = ''
      data.location=${userhome}/.task
      news.version=${pkgs.taskwarrior3.version}

      confirmation=no

      color.project.Todos=yellow

      color.tag.xteam=yellow
      color.tag.urgent=bold red on gray
      color.tag.waiting=blue
    '';
  };

  home.packages = [
    pkgs.taskwarrior3
    pkgs.taskwarrior-tui
  ];
}
