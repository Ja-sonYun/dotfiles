{ pkgs
, lib
, userhome
, ...
}:
let
  # Reminder lists to sync with taskwarrior
  filterLists = [ "Avilen" "Todos" "Work" ];
  filterListsStr = lib.concatStringsSep "|" filterLists;

  hookPath =
    lib.makeBinPath [
      pkgs.jq
      pkgs.sqlite
      pkgs.sketchybar
    ]
    + ":/opt/homebrew/bin";

  makeHook = script: ''
    #!${pkgs.zsh}/bin/zsh -f
      export PATH="${hookPath}:$PATH"
      export FILTER_LISTS="${filterListsStr}"
      source ${script}
  '';

  syncPath =
    lib.makeBinPath [
      pkgs.jq
      pkgs.sqlite
      pkgs.taskwarrior3
      pkgs.coreutils
      pkgs.flock
      pkgs.python314
    ]
    + ":/opt/homebrew/bin";

  task-sync = pkgs.writeScriptBin "task-sync" ''
    #!${pkgs.zsh}/bin/zsh -f
        export PATH="${syncPath}:$PATH"
        export FILTER_LISTS="${filterListsStr}"
        LOCK_FILE="/tmp/task-sync.lock"
        exec 9>"$LOCK_FILE"
        if ! flock -en 9; then
        echo "Another task-sync is running"
        exit 0
        fi
        export TASK_SYNC_RUNNING=1
        source ${./plugins/reminder-sync.sh}
  '';

  task-sync-cron = pkgs.writeShellApplication {
    name = "task-sync-cron";
    runtimeInputs = [
      pkgs.tmux
      task-sync
    ];
    text = ''
      if tmux list-sessions &>/dev/null; then
      task-sync
      fi
    '';
  };
in
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

  home.file."task-hooks/on-add" = {
    executable = true;
    target = ".task/hooks/on-add";
    text = makeHook ./hooks/on-add.sh;
  };

  home.file."task-hooks/on-modify" = {
    executable = true;
    target = ".task/hooks/on-modify";
    text = makeHook ./hooks/on-modify.sh;
  };

  home.packages = [
    pkgs.taskwarrior3
    pkgs.taskwarrior-tui
    task-sync
  ];

  launchd.agents.task-sync = {
    enable = true;
    config = {
      Label = "com.user.task-sync";
      ProgramArguments = [ "${task-sync-cron}/bin/task-sync-cron" ];
      StartInterval = 3600;
      StandardOutPath = "/tmp/task-sync.log";
      StandardErrorPath = "/tmp/task-sync.log";
    };
  };
}
