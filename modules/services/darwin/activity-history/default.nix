{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.services.activityHistory;
  hm = config.home-manager.users.${username};
  settings = pkgs.writeText "activity-history.json" (
    builtins.toJSON {
      inherit (cfg)
        dataDirectory
        stateDirectory
        startPaused
        capture
        integrations
        excludedApps
        ;
      tmux = "${pkgs.tmux}/bin/tmux";
    }
  );
  cli = pkgs.uv.asPackage {
    name = "activity-history-core";
    root = ./scripts;
    entrypoint = "activity-history:main";
  };
  helper = pkgs.writeShellScriptBin "activity-history" ''
    exec ${cli}/bin/activity-history-core --config ${settings} "$@"
  '';
  collector = pkgs.replaceVars ./collector.lua {
    configFile = settings;
    helper = "${helper}/bin/activity-history";
    appsDirectory = ./apps;
  };
  shell = pkgs.replaceVars ./shell.zsh {
    helper = "${helper}/bin/activity-history";
  };
  tmuxEvents = [
    "session-window-changed"
    "window-pane-changed"
    "client-session-changed"
    "client-attached"
    "client-focus-in"
  ];
in
{
  options.services.activityHistory = {
    enable = lib.mkEnableOption "local application and terminal activity history";
    startPaused = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start paused when Hammerspoon starts or reloads.";
    };
    dataDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${hm.xdg.dataHome}/activity-history";
      description = "Absolute directory for dated JSONL history.";
    };
    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${hm.xdg.stateHome}/activity-history";
      description = "Absolute directory for collector state and tmux deduplication.";
    };
    excludedApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Application bundle IDs excluded from recording.";
    };
    capture = {
      intervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Periodic foreground capture interval.";
      };
      debounceMilliseconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 700;
        description = "Delay after the last click, Enter, or context change.";
      };
      onContextChange = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Capture application location after application or window changes.";
      };
      onClick = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Capture application location after mouse clicks.";
      };
      onEnter = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Capture application location after Return or keypad Enter without storing keystrokes.";
      };
    };
    integrations = {
      tmux.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Record local tmux client and pane context.";
      };
      zsh.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Record interactive zsh commands and prompt returns.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.hammerspoon.enable;
        message = "services.activityHistory requires Hammerspoon.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.dataDirectory && lib.hasPrefix "/" cfg.stateDirectory;
        message = "Activity history directories must be absolute paths.";
      }
      {
        assertion = !cfg.integrations.tmux.enable || hm.programs.tmux.enable;
        message = "Activity history tmux integration requires programs.tmux.enable.";
      }
      {
        assertion = !cfg.integrations.zsh.enable || hm.programs.zsh.enable;
        message = "Activity history zsh integration requires programs.zsh.enable.";
      }
    ];
    services.hammerspoon = {
      enable = lib.mkDefault true;
      preparedScripts = [
        {
          name = "activity-history.lua";
          path = collector;
        }
      ];
    };
    home-manager.users.${username} = {
      home.packages = [ helper ];
      programs.zsh-customize = lib.mkIf cfg.integrations.zsh.enable {
        enable = true;
        blocks = [
          {
            order = 900;
            raw = "source ${shell}";
            hooks = {
              zshaddhistory = [ "_activity_history_filter" ];
              preexec = [ "_activity_history_start" ];
              precmd = [ "_activity_history_capture_end" ];
            };
          }
          {
            order = 1200;
            hooks.precmd = [ "_activity_history_finish" ];
          }
        ];
      };
      programs.tmux.hooks = lib.mkIf cfg.integrations.tmux.enable (
        lib.listToAttrs (
          map (event: {
            name = "activityHistory-${event}";
            value = {
              inherit event;
              command = ''run-shell -b "${helper}/bin/activity-history _tmux-event --socket=#{q:socket_path} --session=#{q:hook_session} --window=#{q:hook_window} --pane=#{q:hook_pane} --client=#{q:hook_client} --reason=${event}"'';
            };
          }) tmuxEvents
        )
      );
    };
  };
}
