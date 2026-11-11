{
  config,
  lib,
  ...
}:
let
  agent = config.programs.tmux.extensions.agent;
  inherit (agent) scripts;
  popupScripts = config.programs.tmux.extensions.popup.scripts;
  sharedRootBindings = import ../../shared-root.nix;
  dashboardAction =
    action: "run-shell -b '${agent.dashboardCommand} #{q:socket_path} #{q:session_id} ${action}' ";
in
lib.mkIf agent.enable {
  programs = {
    tmux-menu = {
      menus.menu.items = lib.mkOrder 400 (
        [
          { separator = true; }
          {
            menu = {
              name = "agent";
              shortcut = "a";
              command =
                lib.optionalString config.programs.tmux.extensions.sessionCleanup.enable "_tmux-session-cleanup-register agent && "
                + "direnv exec . agent";
              session = true;
              sessionName = "agent";
              keyTable =
                if config.programs.tmux.extensions.popup.enable then "popup-locked-root" else "common-root";
              sessionOnDir = true;
              runOnRoot = ".root";
              runOnGitRoot = true;
              environment = agent.sessionEnvironment // {
                CTRL_C_AS_CLOSE = "1";
              };
              position = {
                w = "60%";
                h = "55%";
                x = "R";
                y = "P";
              };
            };
          }
        ]
        ++ [
          {
            menu = {
              name = "all agents";
              shortcut = "A";
              command = "${scripts}/overview";
              background = true;
            };
          }
        ]
      );
    };

    tmux = {
      extensions.agent.commands = [
        {
          command = "agent";
          key = "c";
        }
        {
          command = "codex";
          key = "x";
        }
        {
          command = config.programs.codex.defaultProfileName;
          key = "1";
          kind = "codex";
        }
        {
          command = "codex-2";
          key = "2";
          kind = "codex";
        }
        {
          command = "codex-work";
          key = "w";
          kind = "codex";
        }
        {
          command = "claude";
          key = "s";
        }
        {
          command = "claude-work";
          args = [ "--chrome" ];
          key = "a";
          kind = "claude";
        }
        {
          command = "pi";
          key = "p";
        }
        {
          command = "agy";
          kind = "antigravity";
          displayName = "Antigravity";
          key = "g";
        }
        {
          command = "claude";
          args = [ "--chrome" ];
          label = "claude chrome";
          key = "b";
        }
      ];

      bindings.A.command =
        "run-shell -b 'cd -- #{q:pane_current_path} && exec env "
        + "TMUX_MENU_CLIENT=#{q:client_name} TMUX_MENU_PANE=#{q:pane_id} "
        + "TMUX_MENU_ORIGIN_PANE=#{q:pane_id} TMUX_MENU_ORIGIN_WINDOW=#{q:window_id} "
        + "${scripts}/overview'";

      bindings.c.cases = lib.mkBefore [
        {
          whenEnv = [ "TMUX_AGENT_STATUS" ];
          script = agent.menuCommand;
        }
      ];

      keyTables = {
        all-agents-view-root.Any.command = "send-keys";
        all-agents-root = sharedRootBindings // {
          "C-q".command = "switch-client -T all-agents-prefix";
          Left.command = dashboardAction "focus sidebar";
          menuCtrlC = {
            key = "C-c";
            command = "detach-client";
          };
        };

        all-agents-prefix = {
          A.command = dashboardAction "focus viewer";
          "C-c".command = "send-keys C-c";
          d.command = "detach-client";
          f.command = "detach-client";
          "C-f".command = "detach-client";
          "C-r".command = "detach-client";
          w.command = "detach-client";
          s.command = "detach-client";
          k.command = dashboardAction "project-menu #{q:client_name}";
          c.command = dashboardAction "menu #{q:client_name}";
          t.command = dashboardAction "focus sidebar";
          n.command = dashboardAction "select next";
          "C-n" = {
            repeat = true;
            command = dashboardAction "select next";
          };
          p.command = dashboardAction "select previous";
          "C-p" = {
            repeat = true;
            command = dashboardAction "select previous";
          };
          l.command = dashboardAction "select last";
          "0".command = dashboardAction "select 0";
          "1".command = dashboardAction "select 1";
          "2".command = dashboardAction "select 2";
          "3".command = dashboardAction "select 3";
          "4".command = dashboardAction "select 4";
          "5".command = dashboardAction "select 5";
          "6".command = dashboardAction "select 6";
          "7".command = dashboardAction "select 7";
          "8".command = dashboardAction "select 8";
          "9".command = dashboardAction "select 9";
          Up.command = "select-pane -U";
          Down.command = "select-pane -D";
          Left.command = "select-pane -L";
          Right.command = "select-pane -R";
          q.command = "display-panes";
          copy = {
            key = "[";
            command = dashboardAction "copy";
          };
          paste = {
            key = "]";
            command = "paste-buffer -p";
          };
          PPage.command = dashboardAction "copy page-up";
          z.command = dashboardAction "focus viewer";
          m = lib.mkIf config.programs.tmux.extensions.popup.enable {
            command = "switch-client -T popupmove";
          };
          M = lib.mkIf config.programs.tmux.extensions.popup.enable {
            command = ''run-shell -b "${popupScripts}/move reset '#{session_name}'"'';
          };
          Any.command = ''display-message "All Agents: window/session changes disabled"'';
        };
      };
    };

    tmux-customize = {
      sessions.agent.group = "agent";
      groups = {
        agent-dashboard = {
          match.env = "TMUX_AGENT_DASHBOARD";
          priority = 30;
          status.enable = false;
        };
        agent-view = {
          match.env = "TMUX_AGENT_VIEW";
          priority = 20;
          status.enable = false;
          window = agent.windowStyles;
        };
        normal.status.right = lib.mkBefore [ "reconcile" ];
        agent = {
          match.env = "TMUX_AGENT_STATUS";
          priority = 10;
          status = {
            enable = true;
            position = "bottom";
            bg = "default";
            style = "bg=default";
            left = [
              "reconcile"
              "space"
            ];
            right = [ ];
          };
          window = agent.windowStyles;
        };
      };
    };
  };
}
