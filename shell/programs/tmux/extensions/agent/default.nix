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
in
lib.mkIf agent.enable {
  programs = {
    tmux-menu = {
      menus.menu.items = lib.mkOrder 400 [
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
              TMUX_REMAP_CTRL_D = "C-n";
            };
            position = {
              w = "60%";
              h = "55%";
            };
          };
        }
        {
          menu = {
            name = "all agents";
            shortcut = "A";
            command = "${scripts}/overview";
            background = true;
          };
        }
      ];
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
          key = "a";
        }
        {
          command = "pi";
          key = "p";
        }
        {
          command = "claude";
          args = [ "--chrome" ];
          label = "claude chrome";
          key = "b";
        }
      ];

      bindings.c.cases = lib.mkBefore [
        {
          whenEnv = [ "TMUX_AGENT_STATUS" ];
          script = agent.menuCommand;
        }
      ];

      keyTables = {
        all-agents-root = sharedRootBindings // {
          "C-q".command = "switch-client -T all-agents-prefix";
          menuCtrlC = {
            key = "C-c";
            command = "detach-client";
          };
          "C-d".command = "send-keys C-n";
        };

        all-agents-prefix = {
          "C-c".command = "send-keys C-c";
          d.command = "detach-client";
          f.command = "detach-client";
          "C-f".command = "detach-client";
          "C-r".command = "detach-client";
          w.command = "detach-client";
          s.command = "detach-client";
          k.command = "run-shell -b '${config.programs.tmux-menu.showScript} #{q:pane_id} #{q:window_id} #{q:client_name} #{q:pane_current_path}'";
          n.command = "next-window";
          "C-n" = {
            repeat = true;
            command = "next-window";
          };
          p.command = "previous-window";
          "C-p" = {
            repeat = true;
            command = "previous-window";
          };
          l.command = "last-window";
          "0".command = "select-window -t :=0";
          "1".command = "select-window -t :=1";
          "2".command = "select-window -t :=2";
          "3".command = "select-window -t :=3";
          "4".command = "select-window -t :=4";
          "5".command = "select-window -t :=5";
          "6".command = "select-window -t :=6";
          "7".command = "select-window -t :=7";
          "8".command = "select-window -t :=8";
          "9".command = "select-window -t :=9";
          Up.command = "select-pane -U";
          Down.command = "select-pane -D";
          Left.command = "select-pane -L";
          Right.command = "select-pane -R";
          q.command = "display-panes";
          copy = {
            key = "[";
            command = "copy-mode";
          };
          paste = {
            key = "]";
            command = "paste-buffer -p";
          };
          PPage.command = "copy-mode -u";
          z.command = "resize-pane -Z";
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
