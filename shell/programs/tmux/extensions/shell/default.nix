{
  lib,
  ...
}:
let
  tmuxRoot = ../..;
  scripts = "${tmuxRoot}/extensions/shell/scripts";
  agentScripts = "${tmuxRoot}/extensions/agent/scripts";
in
{
  programs.tmux-menu = {
    menus.menu.items = lib.mkOrder 200 [
      {
        menu = {
          name = "shell";
          shortcut = "s";
          command = "_gen-close-hook subshell && /bin/zsh";
          session = true;
          sessionName = "subshell";
          keyTable = "popup-root";
          sessionOnDir = true;
          runOnGitRoot = true;
          position = {
            w = "60%";
            h = "70%";
          };
        };
      }
    ];
  };

  programs.zsh-customize.blocks = [
    {
      order = 1100;
      variables._tmux_update_seq = {
        flags = "-gi";
        value = "0";
      };

      functions = {
        _tmux_set_pane_command = ''
          [[ -n "$TMUX" && -n "$TMUX_PANE" ]] || return
          _tmux_update_seq=$(( _tmux_update_seq + 1 ))
          tmux set-option -p -q -t "$TMUX_PANE" @shell_cmd "''${1%% *}" ';' \
            set-option -p -q -t "$TMUX_PANE" @shell_seq "$_tmux_update_seq" 2>/dev/null
          "${scripts}/update" "$TMUX_PANE" "$_tmux_update_seq" >/dev/null 2>&1 &!
        '';

        _tmux_clear_pane_command = ''
          [[ -n "$TMUX" && -n "$TMUX_PANE" ]] || return
          _tmux_update_seq=$(( _tmux_update_seq + 1 ))
          tmux set-option -p -q -t "$TMUX_PANE" @shell_pwd "$PWD" ';' \
            set-option -p -q -t "$TMUX_PANE" @shell_cmd "''${ZSH_NAME:-zsh}" ';' \
            set-option -p -q -t "$TMUX_PANE" @shell_seq "$_tmux_update_seq" 2>/dev/null
          "${scripts}/update" "$TMUX_PANE" "$_tmux_update_seq" >/dev/null 2>&1 &!
          "${agentScripts}/counts" >/dev/null 2>&1 &!
        '';
      };

      hooks = {
        preexec = [ "_tmux_set_pane_command" ];
        precmd = [ "_tmux_clear_pane_command" ];
      };
    }
  ];

  programs.tmux.hooks = {
    paneTitleNewWindow = {
      event = "after-new-window";
      command = ''run-shell -b "${scripts}/panes #{pane_id}"'';
    };
    paneTitleSelectPane = {
      event = "after-select-pane";
      command = ''run-shell -b "${scripts}/panes #{pane_id}"'';
    };
    paneTitleSelectWindow = {
      event = "after-select-window";
      command = ''run-shell -b "${scripts}/panes #{pane_id}"'';
    };
    paneTitleSplitWindow = {
      event = "after-split-window";
      command = ''run-shell -b "${scripts}/panes #{pane_id}"'';
    };
    paneTitlePaneExited = {
      event = "pane-exited";
      command = ''run-shell -b "${scripts}/panes #{hook_window}"'';
    };
    paneTitlePaneDied = {
      event = "pane-died";
      command = ''run-shell -b "${scripts}/panes #{hook_window}"'';
    };
  };

  programs.tmux-customize = {
    sessions.subshell.group = "shell";

    groups.shell = {
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
    };
  };
}
