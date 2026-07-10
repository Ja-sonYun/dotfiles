{
  pkgs,
  config,
  ...
}:
let
  popupScript = ''
    if tmux show-environment MAIN_POPUP >/dev/null 2>&1; then
      if tmux list-sessions | grep '^main:' | grep -q '(attached)'; then
        tmux detach-client
      else
        tmux switch-client -t main
      fi
    else
      # Record which client the popup is drawn on so the popup-move script
      # (prefix+m inside the popup) can close/reopen it on the right terminal.
      tmux set -g @popup_client "$(tmux display-message -p '#{client_name}')"
      # Reuse the geometry saved by scripts/popup-move/move ("x y w h" in
      # cells) so a moved/resized popup keeps its place across close/open.
      geom="$(tmux show-options -gqv @popup_geom_popup)"
      if [ -n "$geom" ]; then
        set -- $geom
        tmux popup -e POPUP=1 -x "$1" -y "$2" -w "$3" -h "$4" -E "tmux attach -t popup || tmux new -s popup -e MAIN_POPUP=1 -e DEFAULT=1"
      else
        tmux popup -e POPUP=1 -w75% -h70% -E "tmux attach -t popup || tmux new -s popup -e MAIN_POPUP=1 -e DEFAULT=1"
      fi
    fi
  '';

  swapScript = ''
    tmux rename-session -t main _temp_current
    tmux rename-session -t popup _temp_popup
    tmux rename-session -t _temp_current popup
    tmux rename-session -t _temp_popup main
    tmux set-environment -t main -u MAIN_POPUP
    tmux set-environment -t main MAIN 1
    tmux set-environment -t popup -u MAIN
    tmux set-environment -t popup MAIN_POPUP 1
    tmux switch-client -t main
  '';

  agentMenu = ''
    tmux display-menu -T ' agent ' \
      claude c "new-window 'direnv exec . claude'" \
      "claude lmp" l "new-window 'direnv exec . claude-lmp'" \
      codex x "new-window 'direnv exec . codex'" \
      "codex lmp" X "new-window 'direnv exec . codex-lmp'" \
      pi p "new-window 'direnv exec . pi'" \
      "claude chrome" b "new-window 'direnv exec . claude --chrome'"
  '';

in
{
  imports = [ ./tmuxmenu.nix ];

  home.packages = [
    pkgs.pstree
  ];

  programs.tmux = {
    enable = true;

    setServerOptions = {
      escape-time = "30";
    };

    setGlobalOptions = {
      "@menus_trigger" = "'b'";
      prefix = "C-q";
      mouse = "off";
      renumber-windows = "on";
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
      status-keys = "vi";
      status-interval = "10";
      status-left-length = "50";
      status-right-length = "120";
      status = "on";
    };

    setWindowOptions = {
      allow-set-title = "off";
      mode-keys = "vi";
      monitor-bell = "off";
      "@agent_idle_counts_display" = "0";
      "@agent_running_counts_display" = "0";
      "@agent_waiting_counts_display" = "0";
    };

    enableVimIntegration = true;

    hooks = {
      paneTitleNewWindow = {
        event = "after-new-window";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/shell-session/panes #{pane_id}"'';
      };
      paneTitleSelectPane = {
        event = "after-select-pane";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/shell-session/panes #{pane_id}"'';
      };
      paneTitleSelectWindow = {
        event = "after-select-window";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/shell-session/panes #{pane_id}"'';
      };
      paneTitleSplitWindow = {
        event = "after-split-window";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/shell-session/panes #{pane_id}"'';
      };
      paneTitlePaneExited = {
        event = "pane-exited";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/shell-session/panes #{hook_window}"'';
      };
      paneTitlePaneDied = {
        event = "pane-died";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/shell-session/panes #{hook_window}"'';
      };
      agentSessionCountsNewWindow = {
        event = "after-new-window";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/counts"'';
      };
      agentSessionCountsSelectPane = {
        event = "after-select-pane";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/counts"'';
      };
      agentSessionCountsSelectWindow = {
        event = "after-select-window";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/counts"'';
      };
      agentSessionCountsSplitWindow = {
        event = "after-split-window";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/counts"'';
      };
      agentStatusNewSession = {
        event = "after-new-session";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/status init #{pane_id}"'';
      };
      agentStatusNewWindow = {
        event = "after-new-window";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/status init #{pane_id}"'';
      };
      agentStatusSelectWindow = {
        event = "after-select-window";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/status init #{pane_id}"'';
      };
      agentStatusClientAttached = {
        event = "client-attached";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/status init #{pane_id}"'';
      };
      agentStatusClientSessionChanged = {
        event = "client-session-changed";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/status init #{pane_id}"'';
      };
      agentStatusPaneExited = {
        event = "pane-exited";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/status delete #{hook_pane} #{session_name}"'';
      };
      agentStatusPaneDied = {
        event = "pane-died";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/status delete #{hook_pane} #{session_name}"'';
      };
      agentStatusWindowUnlinked = {
        event = "window-unlinked";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/status refresh"'';
      };
      agentStatusSessionClosed = {
        event = "session-closed";
        command = ''run-shell -b "$TMUX_CONFIG/scripts/agent-session/status refresh"'';
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
        script = ''
          if tmux show-environment TMUX_REMAP_CTRL_D >/dev/null 2>&1; then
            tmux send-keys "$(tmux show-environment TMUX_REMAP_CTRL_D | cut -d= -f2-)"
          else
            tmux send-keys C-d
          fi
        '';
      };
      menuCtrlCRoot = {
        key = "C-c";
        table = "root";
        cases = [
          {
            whenEnv = [ "CTRL_C_AS_CLOSE" ];
            command = "detach";
          }
          { command = "send-keys C-c"; }
        ];
      };
      C-c = {
        noDefault = true;
        cases = [
          {
            whenEnv = [ "CTRL_C_AS_CLOSE" ];
            command = "send-keys C-c";
          }
        ];
      };
      w = {
        cases = [
          {
            whenEnv = [ "MENU_POPUP" ];
            command = "detach";
          }
        ];
      };
      s = {
        cases = [
          {
            whenEnv = [ "MENU_POPUP" ];
            command = "detach";
          }
        ];
      };
      c = {
        cases = [
          {
            whenEnv = [ "TMUX_AGENT_STATUS" ];
            script = agentMenu;
          }
          {
            whenEnv = [ "NO_WINDOW_MGNT" ];
            command = "detach";
          }
        ];
      };
      n = {
        cases = [
          {
            whenEnv = [ "NO_WINDOW_MGNT" ];
            unlessEnv = [ "TMUX_AGENT_STATUS" ];
            command = "detach";
          }
        ];
      };
      C-n = {
        repeat = true;
        cases = [
          {
            whenEnv = [ "NO_WINDOW_MGNT" ];
            unlessEnv = [ "TMUX_AGENT_STATUS" ];
            command = "detach";
          }
          { command = "next-window"; }
        ];
      };
      p = {
        cases = [
          {
            whenEnv = [ "NO_WINDOW_MGNT" ];
            unlessEnv = [ "TMUX_AGENT_STATUS" ];
            command = "detach";
          }
        ];
      };
      C-p = {
        repeat = true;
        cases = [
          {
            whenEnv = [ "NO_WINDOW_MGNT" ];
            unlessEnv = [ "TMUX_AGENT_STATUS" ];
            command = "detach";
          }
          { command = "previous-window"; }
        ];
      };
      "%" = {
        cases = [
          {
            whenEnv = [ "NO_WINDOW_MGNT" ];
            command = "detach";
          }
        ];
      };
      menuQuote = {
        key = "'\"'";
        cases = [
          {
            whenEnv = [ "NO_WINDOW_MGNT" ];
            command = "detach";
          }
        ];
      };
      "!" = {
        cases = [
          {
            whenEnv = [ "NO_WINDOW_MGNT" ];
            command = "detach";
          }
        ];
      };
      k = {
        command = "run-shell ${config.programs.tmux-menu.showScript}";
      };
      M = {
        command = ''run-shell "TMUX_MENU_BIN=/Users/jaykuroyanagi/Projects/tmux-easy-menu/target/debug/tmux-menu ${config.programs.tmux-menu.showScript}"'';
      };

      f = {
        cases = [
          {
            unlessEnv = [ "MAIN" ];
            command = "detach";
          }
          { script = popupScript; }
        ];
      };
      "C-f" = {
        cases = [
          {
            unlessEnv = [ "MAIN" ];
            command = "detach";
          }
          { script = popupScript; }
        ];
      };
      "C-r" = {
        cases = [
          {
            unlessEnv = [ "MAIN" ];
            command = "detach";
          }
          { script = swapScript; }
        ];
      };
      d = {
        noDefault = true;
        cases = [
          {
            unlessEnv = [ "DEFAULT" ];
            command = "detach";
          }
        ];
      };

      # popupmove works only in popup content sessions: only their key presses reach this server.
      m = {
        cases = [
          {
            whenEnv = [ "MAIN_POPUP" ];
            command = "switch-client -T popupmove";
          }
          {
            whenEnv = [ "MENU_POPUP" ];
            command = "switch-client -T popupmove";
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

    extraConfig = ''
      set -gu terminal-features
      set -ga terminal-features ",xterm*:RGB"
      set-environment -g 'IGNOREEOF' 10

      # popup move/resize mode: enter with prefix+m from inside a popup, any
      # unbound key (e.g. Escape) leaves the mode. Args are "dx dy dw dh" in
      # cells; the script re-enters this table after each step, so keys can
      # be pressed repeatedly. y is the popup's bottom edge, so j/J grow downward.
      bind-key -T popupmove h run-shell -b "$TMUX_CONFIG/scripts/popup-move/move -5 0 0 0"
      bind-key -T popupmove l run-shell -b "$TMUX_CONFIG/scripts/popup-move/move 5 0 0 0"
      bind-key -T popupmove j run-shell -b "$TMUX_CONFIG/scripts/popup-move/move 0 2 0 0"
      bind-key -T popupmove k run-shell -b "$TMUX_CONFIG/scripts/popup-move/move 0 -2 0 0"
      bind-key -T popupmove H run-shell -b "$TMUX_CONFIG/scripts/popup-move/move 0 0 -5 0"
      bind-key -T popupmove L run-shell -b "$TMUX_CONFIG/scripts/popup-move/move 0 0 5 0"
      bind-key -T popupmove J run-shell -b "$TMUX_CONFIG/scripts/popup-move/move 0 0 0 2"
      bind-key -T popupmove K run-shell -b "$TMUX_CONFIG/scripts/popup-move/move 0 0 0 -2"
    '';
  };

  home.sessionVariables.TMUX_CONFIG = config.programs.tmux-menu.configDir;

  programs.tmux-customize = {
    enable = true;
    defaultGroup = "normal";

    segments = {
      space = "printf ' '";

      reconcile = ''[ -n "''${TMUX_CONFIG:-}" ] && "$TMUX_CONFIG/scripts/agent-session/reconcile" >/dev/null 2>&1 || true'';

      prompt = ''printf '#[fg=red]X #[fg=default]%s>> ' "''${USER:-$(whoami)}"'';

      messages = ''
        messages_dir="/tmp/tmux-status-messages"
        mkdir -p -- "$messages_dir"
        msgs=()
        shopt -s nullglob
        for f in "$messages_dir"/*; do
          line="$(tail -n 1 "$f" 2>/dev/null)"
          [ -n "$line" ] && msgs+=("$line")
        done
        message=""
        for i in "''${!msgs[@]}"; do
          [ "$i" -ne 0 ] && message+=" | "
          message+="''${msgs[$i]}"
        done
        printf '%s - ' "$message"
      '';

      git = ''
        shorten_string() {
          local maxlen="$1"; shift; local str="$*"
          if [ "''${#str}" -le "$maxlen" ]; then printf '%s' "$str"; return; fi
          local end_len=$(( maxlen / 2 ))
          local start_len=$(( maxlen - end_len - 1 ))
          printf '%s…%s' "''${str:0:start_len}" "''${str: -end_len}"
        }
        branch="$(git symbolic-ref --short HEAD 2>/dev/null)"
        if [ -n "$branch" ]; then
          branch="$(shorten_string 20 "$branch")"
          printf '#[fg=red]Git#[fg=default](#[fg=red]%s#[fg=default]):' "$branch"
        fi
      '';

      pwd = ''
        p="''${PWD/#$HOME/\~}"
        oldIFS="$IFS"; IFS=/; read -ra parts <<< "$p"; IFS="$oldIFS"
        n=''${#parts[@]}
        out=()
        for (( i=0; i<n; i++ )); do
          seg="''${parts[$i]}"
          if [ "$seg" != "~" ] && [ -n "$seg" ] && [ "$i" -lt "$(( n - 1 ))" ]; then
            seg="''${seg:0:3}…"
          fi
          out+=("$seg")
        done
        IFS=/; res="''${out[*]}"; IFS="$oldIFS"
        printf '%s' "$res"
      '';
    };

    groups = {
      normal = {
        status = {
          position = "top";
          bg = "#FFFFFF";
          left = [ "prompt" ];
          right = [
            "reconcile"
            "messages"
            "git"
            "pwd"
          ];
        };
        window = {
          format = "#I:#{?#{@panes},#{@panes},#W} #[push-default]#{@agent_idle_counts_display}:#{@agent_running_counts_display}:#{@agent_waiting_counts_display}#[pop-default]";
          currentFormat = "#[fg=white]#[bg=green]▌#[default]#[bg=green]#I:#{?#{@panes},#{@panes},#W} #[push-default]#{@agent_idle_counts_display}:#{@agent_running_counts_display}:#{@agent_waiting_counts_display}#[pop-default]#[default]#[fg=white]#[bg=green]▐#[default]";
        };
        color = "green";
      };

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
        window = {
          format = "#[bg=default]#{@agent_fg}▐#{@agent_bg}#[fg=black]#I:#W#{@agent_fg}#[bg=default]▌#[default]";
          currentFormat =
            let
              highlightColor = "magenta";
            in
            "#{@agent_bg}#[fg=${highlightColor}]▌#[fg=black]#I:#{@agent_name}:#{@agent_state}#{@agent_fg}#[fg=${highlightColor}]▐#[default]";
        };
        color = "red";
      };

      shell = {
        status = {
          enable = true;
          position = "top";
          bg = "#FFFFFF";
          left = [ "space" ];
          right = [ ];
        };
        window = {
          format = "#I:#{?#{@panes},#{@panes},#{pane_current_command}}";
          currentFormat = "#[fg=white]#[bg=green]▌#[default]#[bg=green]#I:#{?#{@panes},#{@panes},#{pane_current_command}}#[default]#[fg=white]#[bg=green]▐#[default]";
        };
        color = "green";
      };
    };

    sessions = {
      main = {
        group = "normal";
        environment = {
          MAIN = "1";
          DEFAULT = "1";
        };
        unicode = true;
      };
      popup = {
        group = "normal";
        environment = {
          MAIN_POPUP = "1";
          DEFAULT = "1";
        };
      };
      subshell = {
        group = "shell";
      };
      agent = {
        group = "agent";
      };
    };

    launcher = {
      enable = true;
      startSessions = [
        "popup"
        "main"
      ];
      attach = "main";
    };
  };

  programs.zsh-customize.commands = {
    _gen-close-hook = {
      description = "Generate a tmux close hook for a given command";
      body = ''
        command="$1"
        mkdir -p .hooks/on_leave .hooks/on_exit

        cat <<'EOF' >".hooks/on_exit/close_''${command}.tmp"
        # hook-version: 1
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
