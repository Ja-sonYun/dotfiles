{
  lib,
  pkgs,
  ...
}:
let
  tmuxRoot = ../..;
  scripts = "${tmuxRoot}/extensions/monitor/scripts";
in
lib.mkIf pkgs.stdenv.isDarwin {
  programs.tmux-menu.menus = {
    menu.items = lib.mkOrder 500 [
      { separator = true; }
      {
        menu = {
          name = "pane monitor";
          shortcut = "m";
          nextMenu = "pane-monitor";
        };
      }
    ];

    pane-monitor = {
      title = "pane monitor";
      items = [
        {
          menu = {
            name = "monitor current pane globally";
            shortcut = "g";
            command = "${scripts}/pane-monitor add-global";
            background = true;
          };
        }
        {
          menu = {
            name = "monitor current pane locally";
            shortcut = "l";
            command = "${scripts}/pane-monitor add-local";
            background = true;
          };
        }
        { separator = true; }
        {
          menu = {
            name = "toggle global";
            shortcut = "t";
            command = "${scripts}/pane-monitor toggle-global";
            background = true;
          };
        }
        {
          menu = {
            name = "toggle local";
            shortcut = "T";
            command = "${scripts}/pane-monitor toggle-local";
            background = true;
          };
        }
        {
          menu = {
            name = "remove global";
            shortcut = "r";
            command = "${scripts}/pane-monitor remove-global";
            background = true;
          };
        }
        {
          menu = {
            name = "remove local";
            shortcut = "R";
            command = "${scripts}/pane-monitor remove-local";
            background = true;
          };
        }
        { separator = true; }
        {
          menu = {
            name = "set size";
            shortcut = "s";
            command = ''tmux command-prompt -p "width:","height:" "run-shell '${scripts}/pane-monitor size %1 %2'"'';
            background = true;
          };
        }
      ];
    };
  };

  programs.tmux.hooks = {
    paneMonitorClientSessionChanged = {
      event = "client-session-changed";
      command = ''run-shell -b "${scripts}/pane-monitor follow"'';
    };
    paneMonitorWindowResized = {
      event = "window-resized";
      command = ''run-shell -b "${scripts}/pane-monitor resize #{hook_window}"'';
    };
    paneMonitorSessionWindowChanged = {
      event = "session-window-changed";
      command = ''run-shell -b -d 0.1 "${scripts}/pane-monitor follow #{hook_window}"'';
    };
    paneMonitorPaneExited = {
      event = "pane-exited";
      command = ''run-shell -b "${scripts}/pane-monitor cleanup #{hook_pane}"'';
    };
  };
}
