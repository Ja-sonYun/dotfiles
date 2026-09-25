{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tmux.extensions.agent;
  tmuxRoot = ../..;
  scripts = "${tmuxRoot}/extensions/agent/scripts";
  stateNotify = pkgs.writeShellScript "tmux-agent-notify" ''
    [[ -n "''${TMUX_PANE:-}" ]] || exit 0
    exec ${scripts}/status init
  '';
  stateColor =
    colors:
    "#{?#{==:#{@agent_state},running},${colors.running},#{?#{==:#{@agent_state},waiting},${colors.waiting},#{?#{==:#{@agent_state},error},${colors.error},${colors.idle}}}}";
  agentInactiveColor = stateColor cfg.colors.inactive;
  agentActiveColor = stateColor cfg.colors.active;
  colorOptions = lib.mapAttrs (
    _: default:
    lib.mkOption {
      type = lib.types.str;
      inherit default;
      description = "tmux color for this agent state.";
    }
  );
  directAgents = lib.filter (agent: agent.command != "agent") cfg.commands;
  agentKinds = lib.unique (
    map (agent: if agent.kind == null then agent.command else agent.kind) directAgents
  );
  agentDisplayNames = builtins.listToAttrs (
    map (
      agent:
      lib.nameValuePair agent.command (
        if agent.displayName == null then agent.command else agent.displayName
      )
    ) directAgents
  );
  agentCommandMap = lib.concatStringsSep " " (
    lib.unique (
      map (
        agent: "${agent.command}=${if agent.kind == null then agent.command else agent.kind}"
      ) directAgents
    )
    ++ map (kind: "${kind}-*=${kind}") agentKinds
  );
  agentMenu =
    "tmux display-menu -T ' agent ' "
    + lib.escapeShellArgs (
      lib.concatMap (
        agent:
        let
          command = lib.escapeShellArgs (
            [
              "direnv"
              "exec"
              "."
              agent.command
            ]
            ++ agent.args
          );
        in
        [
          (if agent.label == null then agent.command else agent.label)
          agent.key
          "new-window ${lib.escapeShellArg command}"
        ]
      ) cfg.commands
    );
in
{
  imports = [ ./hooks.nix ];

  options.programs.tmux.extensions.agent = {
    enable = lib.mkEnableOption "AI agent integration with tmux";
    commands = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            command = lib.mkOption {
              type = lib.types.str;
            };
            key = lib.mkOption {
              type = lib.types.str;
            };
            args = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            kind = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            label = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            displayName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
          };
        }
      );
      default = [ ];
      description = "Agent commands for menus and status tracking.";
    };
    mainSession = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Session displaying project agent counts.";
    };
    colors = {
      counts = colorOptions {
        idle = "#c7ccd4";
        running = "#ffd866";
        waiting = "#ff6b6b";
      };
      state = colorOptions {
        idle = "color244";
        running = "yellow";
        waiting = "red";
        error = "red";
      };
      active = colorOptions {
        idle = "#e4e7ec";
        running = "#ffd000";
        waiting = "#ff4040";
        error = "#ff4040";
      };
      inactive = colorOptions {
        idle = "#7a8088";
        running = "#9e8c56";
        waiting = "#b0777d";
        error = "#b0777d";
      };
    };
    scripts = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = scripts;
    };
    stateNotify = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      default = stateNotify;
    };
    menuCommand = lib.mkOption {
      type = lib.types.lines;
      readOnly = true;
      internal = true;
      default = agentMenu;
    };
    countFormat = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = "#[push-default]#{@agent_counts_display}#[pop-default]";
    };
    sessionEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      default = {
        TMUX_AGENT_STATUS = "1";
        TMUX_TITLE_OWNER = "agent";
        TMUX_POPUP_KEEP_OPEN = "1";
        STATE_COMMAND_NOTIFY = "${stateNotify}";
      };
    };
    windowStyles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      default = {
        format = "#[bg=default,fg=${agentInactiveColor}]▐#[bg=${agentInactiveColor},fg=black]#{?#{==:#{session_name},_popup_all_agents},#{b:@agent_project} · ,}#W#[bg=default,fg=${agentInactiveColor}]▌#[default]";
        currentFormat = "#[bg=${agentActiveColor},fg=magenta,nobold]▌#[fg=black,bold]#{?#{==:#{session_name},_popup_all_agents},#{b:@agent_project} · ,}#{@agent_display_name}:#{@agent_state}#[fg=magenta,nobold]▐#[default]";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs = {
      tmux = {
        extensions.monitor.afterCreateCommands = [ "${scripts}/counts" ];
        extraConfig = ''
          set-option -g @agent_command_map ${lib.escapeShellArg agentCommandMap}
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              command: displayName:
              "set-option -g ${lib.escapeShellArg "@agent_display_${command}"} ${lib.escapeShellArg displayName}"
            ) agentDisplayNames
          )}
        '';

        hooks = {
          agentSessionCountsNewWindow = {
            event = "after-new-window";
            command = ''run-shell -b "${scripts}/counts"'';
          };
          agentSessionCountsSelectPane = {
            event = "after-select-pane";
            command = ''run-shell -b "${scripts}/counts"'';
          };
          agentSessionCountsSelectWindow = {
            event = "after-select-window";
            command = ''run-shell -b "${scripts}/counts"'';
          };
          agentSessionCountsSplitWindow = {
            event = "after-split-window";
            command = ''run-shell -b "${scripts}/counts"'';
          };
          agentSessionCountsClientSessionChanged = {
            event = "client-session-changed";
            command = ''run-shell -b "${scripts}/counts"'';
          };
          agentStatusNewSession = {
            event = "after-new-session";
            command = ''run-shell -b "${scripts}/status init #{pane_id} #{q:session_id}"'';
          };
          agentStatusNewWindow = {
            event = "after-new-window";
            command = ''run-shell -b "${scripts}/status init #{pane_id} #{q:session_id}"'';
          };
          agentStatusPaneExited = {
            event = "pane-exited";
            command = ''run-shell -b "${scripts}/status delete #{hook_pane} #{q:@agent_session_id}"'';
          };
          agentStatusPaneDied = {
            event = "pane-died";
            command = ''run-shell -b "${scripts}/status delete #{hook_pane} #{q:@agent_session_id}"'';
          };
          agentStatusWindowUnlinked = {
            event = "window-unlinked";
            command = ''run-shell -b "${scripts}/status refresh"'';
          };
          agentStatusSessionClosed = {
            event = "session-closed";
            command = ''run-shell -b "${scripts}/status refresh"'';
          };
        };

        setGlobalOptions = {
          "@agent_main_session" = lib.escapeShellArg cfg.mainSession;
        }
        // lib.mapAttrs' (
          state: color: lib.nameValuePair "@agent_count_color_${state}" (lib.escapeShellArg color)
        ) cfg.colors.counts
        // lib.mapAttrs' (
          state: color: lib.nameValuePair "@agent_state_color_${state}" (lib.escapeShellArg color)
        ) cfg.colors.state;
      };
      tmux-customize.segments.reconcile = ''"${scripts}/reconcile" >/dev/null 2>&1 &'';

      zsh-customize.blocks = [
        {
          order = 1100;
          variables._tmux_count_pwd = {
            flags = "-g";
            value = "";
          };
          functions._tmux_update_agent_counts = ''
            [[ -n "$TMUX" && -n "$TMUX_PANE" ]] || return
            if [[ "$_tmux_count_pwd" != "$PWD" ]]; then
              _tmux_count_pwd="$PWD"
              "${scripts}/counts" >/dev/null 2>&1 &!
            fi
          '';
          hooks.precmd = [
            {
              function = "_tmux_update_agent_counts";
              tmuxOnly = true;
            }
          ];
        }
      ];
    };
  };
}
