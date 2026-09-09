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
  aiAgents = import ./extensions/ai-agents.nix { inherit lib pkgs helper; };
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
      eventObservers = [ aiAgents.observerCommand ];
    }
  );
  cli = pkgs.uv.asPackage {
    name = "activity-history-core";
    root = ./scripts;
    entrypoint = "activity-history:main";
  };
  helper = pkgs.writeShellScriptBin "activity-history" ''
    if [[ "''${1-}" == _tmux-lifecycle ]]; then
      set -- "$@" --at="$EPOCHREALTIME"
    fi
    if [[ -t 1 && ( "''${1-}" == show || "''${1-}" == today ) ]]; then
      ${cli}/bin/activity-history-core --config ${settings} "$@" | ${pkgs.moor}/bin/moor
      pipeline_status=("''${PIPESTATUS[@]}")
      if (( pipeline_status[0] != 0 )); then
        exit "''${pipeline_status[0]}"
      fi
      exit "''${pipeline_status[1]}"
    fi
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
    "client-detached"
    "client-focus-in"
    "session-created"
    "session-closed"
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
      idleThresholdSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "Input inactivity threshold for idle state events.";
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
      imports = [
        aiAgents.homeManagerModule
      ];
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
              zshexit = [ "_activity_history_session_end" ];
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
          map (
            event:
            let
              clientEvent = builtins.elem event [
                "client-attached"
                "client-session-changed"
              ];
              clientMatches = "#{&&:#{&&:#{hook_client},#{session_id}},#{&&:#{==:#{client_name},#{hook_client}},#{==:#{session_name},#{client_session}}}}";
              session = if clientEvent then "#{?${clientMatches},#{q:session_id},}" else "#{q:hook_session}";
              sessionName =
                if clientEvent then "#{?${clientMatches},#{q:session_name},}" else "#{q:hook_session_name}";
              arguments = "--socket=#{q:socket_path} --server-pid=#{pid} --server-started-at=#{start_time} --session=${session} --session-name=${sessionName} --window=#{q:hook_window} --pane=#{q:hook_pane} --client=#{q:hook_client} --reason=${event}";
              synchronous = builtins.elem event [
                "client-attached"
                "client-detached"
                "client-session-changed"
                "session-created"
                "session-closed"
              ];
              # if-shell registers its job before tmux's final-session exit check.
              record = lib.optionalString synchronous ''if-shell "${helper}/bin/activity-history _tmux-lifecycle ${arguments}" "" ; '';
            in
            {
              name = "activityHistory-${event}";
              value = {
                inherit event;
                command = record + ''run-shell -b "${helper}/bin/activity-history _tmux-event ${arguments}"'';
              };
            }
          ) tmuxEvents
        )
      );
    };
  };
}
