{ config, lib, ... }:
let
  sharedRootBindings = import ./shared-root.nix;
in
{
  programs.tmux = {
    setGlobalOptions = {
      "@menus_trigger" = "'b'";
      prefix = "C-q";
      key-table = "common-root";
    };

    enableVimIntegration = true;

    unbind = [
      { key = "C-o"; }
      { key = "C-f"; }
      { key = "C-e"; }
      { key = "C-t"; }
      { key = "C-r"; }
      { key = "o"; }
      { key = "Space"; }
      { key = "'&'"; }
      { key = "X"; }
      {
        key = "$";
        table = null;
      }
    ];

    bindings = {
      H = {
        repeat = true;
        command = "resize-pane -L 10";
      };
      J = {
        repeat = true;
        command = "resize-pane -D 10";
      };
      K = {
        repeat = true;
        command = "resize-pane -U 10";
      };
      L = {
        repeat = true;
        command = "resize-pane -R 10";
      };

      ">" = {
        repeat = true;
        command = "swap-window -d -t :+1";
      };
      "<" = {
        repeat = true;
        command = "swap-window -d -t :-1";
      };
      "S-." = {
        command = "swap-window -d -t :+1";
      };
      "S-," = {
        command = "swap-window -d -t :-1";
      };

      E = {
        command = ''setw synchronize-panes \; display "synchronize-panes #{?pane_synchronized,on,off}"'';
      };

      v = {
        table = "copy-mode-vi";
        command = "send-keys -X begin-selection";
      };
      V = {
        table = "copy-mode-vi";
        command = "send-keys -X select-line";
      };
      "C-v" = {
        table = "copy-mode-vi";
        command = "send-keys -X rectangle-toggle";
      };
      Enter = {
        table = "copy-mode-vi";
        command = "send-keys -X copy-selection-and-cancel";
      };

      k = {
        command = "run-shell -b '${config.programs.tmux-menu.showScript} #{q:pane_id} #{q:window_id} #{q:client_name} #{q:pane_current_path}'";
      };

      t =
        lib.mkIf
          (config.programs.tmux.extensions.shell.enable || config.programs.tmux.extensions.agent.enable)
          {
            cases =
              lib.optionals config.programs.tmux.extensions.shell.enable [
                {
                  match = "test #{q:session_name} = main";
                  command = ''
                    run-shell -C 'display-popup -E -w 60% -h 40% -x C -y C ${config.programs.tmux.extensions.shell.pickerCommand} main #{q/a:client_name}'
                  '';
                }
              ]
              ++ lib.optionals config.programs.tmux.extensions.agent.enable [
                {
                  whenEnv = [ "TMUX_AGENT_STATUS" ];
                  command = config.programs.tmux.extensions.agent.pickerAction;
                }
              ];
          };

      B = {
        command = "display-message '#{cursor_x} #{cursor_y}'";
      };
      "&" = {
        command = "next-layout";
      };
      X = {
        command = "kill-window";
      };
    };

    keyTables.common-root = sharedRootBindings;
  };
}
