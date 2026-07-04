{
  pkgs,
  config,
  ...
}:
{
  imports = [ ./tmuxmenu.nix ];

  home.packages = [ pkgs.pstree ];

  programs.tmux = {
    enable = true;

    setServerOptions = {
      escape-time = "30";
    };

    setGlobalOptions = {
      "@menus_trigger" = "'b'";
      prefix = "C-q";
      mouse = "off";
      history-limit = "50000";
      default-terminal = ''"tmux-256color"'';
      allow-passthrough = "on";
      set-clipboard = "on";
      focus-events = "on";
      pane-border-style = "'bg=default fg=color231'";
      pane-active-border-style = "'bg=default fg=color231'";
      copy-mode-line-numbers = "hybrid";
      copy-mode-line-number-style = "'fg=color244,bg=default'";
      copy-mode-current-line-number-style = "'fg=green,bg=default'";
      status-bg = ''"#FFFFFF"'';
      status-keys = "vi";
      status-interval = "10";
      status-position = "top";
      status-left-length = "50";
      status-right-length = "120";
      status-right = ''"#(cd #{q:pane_current_path};$TMUX_CONFIG/scripts/tmux-status-right)"'';
      status-left = ''"#(cd #{q:pane_current_path};$TMUX_CONFIG/scripts/tmux-status-left)"'';
      status = "on";
    };

    setWindowOptions = {
      allow-set-title = "off";
      mode-keys = "vi";
      window-status-format = ''"#I:#T"'';
      window-status-current-format = ''"#[fg=white]#[bg=green]▌#[default]#[bg=green]#I:#T#[default]#[fg=white]#[bg=green]▐#[default]"'';
    };

    enableVimIntegration = true;

    hooks = {
      paneTitleNewWindow = {
        event = "after-new-window";
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-update-pane-title #{pane_id}"'';
      };
      paneTitleSelectPane = {
        event = "after-select-pane";
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-update-pane-title #{pane_id}"'';
      };
      paneTitleSelectWindow = {
        event = "after-select-window";
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-update-pane-title #{pane_id}"'';
      };
      paneTitleSplitWindow = {
        event = "after-split-window";
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-update-pane-title #{pane_id}"'';
      };
    };

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

      "S-left" = {
        table = "root";
        command = "select-pane -L";
      };
      "S-down" = {
        table = "root";
        command = "select-pane -D";
      };
      "S-up" = {
        table = "root";
        command = "select-pane -U";
      };
      "S-right" = {
        table = "root";
        command = "select-pane -R";
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
        command = ''send-keys -X copy-pipe-and-cancel "pbcopy"'';
      };

      # Ghostty F-keys (root): F7/F8 re-inject csi-u for node, F1-F12 otherwise swallowed
      F7 = {
        table = "root";
        command = "if-shell -F '#{==:#{pane_current_command},node}' 'send-keys -H 1b 5b 31 33 3b 32 75' 'send-keys Enter'";
      };
      F8 = {
        table = "root";
        command = "if-shell -F '#{==:#{pane_current_command},node}' 'send-keys -H 1b 5b 31 33 3b 35 75' 'send-keys Enter'";
      };
      F1 = {
        table = "root";
        command = "set -gq @nop 1";
      };
      F2 = {
        table = "root";
        command = "set -gq @nop 1";
      };
      F3 = {
        table = "root";
        command = "set -gq @nop 1";
      };
      F4 = {
        table = "root";
        command = "set -gq @nop 1";
      };
      F5 = {
        table = "root";
        command = "set -gq @nop 1";
      };
      F6 = {
        table = "root";
        command = "set -gq @nop 1";
      };
      F9 = {
        table = "root";
        command = "set -gq @nop 1";
      };
      F10 = {
        table = "root";
        command = "set -gq @nop 1";
      };
      F11 = {
        table = "root";
        command = "set -gq @nop 1";
      };
      F12 = {
        table = "root";
        command = "set -gq @nop 1";
      };

      C-d = {
        table = "root";
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh nC-d"'';
      };
      menuCtrlCRoot = {
        key = "C-c";
        table = "root";
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh nC-c"'';
      };
      C-c = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh C-c"'';
      };
      w = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh w"'';
      };
      s = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh s"'';
      };
      c = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh c"'';
      };
      n = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh n"'';
      };
      C-n = {
        repeat = true;
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh n"'';
      };
      p = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh p"'';
      };
      C-p = {
        repeat = true;
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh p"'';
      };
      "%" = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh %"'';
      };
      menuQuote = {
        key = "'\"'";
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh '\"'"'';
      };
      "!" = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh !"'';
      };
      k = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh k"'';
      };
      M = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh M"'';
      };

      f = {
        command = "if-shell '! tmux show-environment MAIN >/dev/null 2>&1' 'detach' 'run-shell \"$TMUX_CONFIG/scripts/tmux-popup.sh top\"'";
      };
      "C-f" = {
        command = "if-shell '! tmux show-environment MAIN >/dev/null 2>&1' 'detach' 'run-shell \"$TMUX_CONFIG/scripts/tmux-popup.sh bottom\"'";
      };
      "C-r" = {
        command = "if-shell '! tmux show-environment MAIN >/dev/null 2>&1' 'detach' 'run-shell \"$TMUX_CONFIG/scripts/swap.sh\"'";
      };
      d = {
        command = ''run-shell "$TMUX_CONFIG/scripts/tmux-key-handler.sh d"'';
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

    extraConfig = ''
      set -gu terminal-features
      set -ga terminal-features ",xterm*:RGB"
      set-environment -g 'IGNOREEOF' 10
    '';
  };

  home.sessionVariables.TMUX_CONFIG = config.programs.tmux-menu.configDir;

  home.shellAliases = {
    tm = toString ./scripts/tmux;
  };

  programs.zshFunc = {
    _gen-close-hook = {
      description = "Generate a tmux close hook for a given command";
      command = ''
        command="$1"
        mkdir -p .hooks/on_leave .hooks/on_exit

        cat <<'EOF' >".hooks/on_exit/close_''${command}.tmp"
        if [[ ! -z "$TMUX" ]]; then
            hooks_dir=$(find_hooks_dir "$OLDPWD")
            if [[ -n "$hooks_dir" ]]; then
                project_root=$(dirname "$hooks_dir")
                name="git_root_''${command}_$(printf '%s' "$project_root:" | sed -e 's/[\/ ]/_/g')"
                tmux_session_name=$(tmux list-sessions | awk -F: -v pat="$name" 'index($0,pat){print $1}')
                if [[ -n "$tmux_session_name" ]]; then
                    if ask_yes_no "Kill ''${command}"; then
                        tmux kill-session -t "$tmux_session_name" 2>/dev/null && \
                            echo "Closed tmux session for ''${command}_$(echo "$project_root" | tr '/' '_' | tr ' ' '_')" || \
                            echo "Failed to close tmux session for ''${command}_$(echo "$project_root" | tr '/' '_' | tr ' ' '_')"
                    else
                        echo "Cancelled."
                    fi
                fi
            fi
        fi
        EOF

        sed "s/\''${command}/$command/g" ".hooks/on_exit/close_''${command}.tmp" >".hooks/on_exit/close_''${command}"
        rm ".hooks/on_exit/close_''${command}.tmp"

        cp ".hooks/on_exit/close_''${command}" ".hooks/on_leave/close_''${command}"
      '';
    };
  };
}
