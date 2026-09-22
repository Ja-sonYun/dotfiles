{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.tmux.extensions.shell;
  scripts = "${../..}/extensions/shell/scripts";
in
{
  options.programs.tmux.extensions.shell = {
    enable = lib.mkEnableOption "tmux shell title updates";
    scripts = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = scripts;
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.zsh.enable && config.programs.zsh-customize.enable;
        message = "tmux shell integration requires programs.zsh and programs.zsh-customize.";
      }
    ];
    programs.zsh-customize.blocks = [
      {
        order = 1100;
        variables = {
          _tmux_update_seq = {
            flags = "-gi";
            value = "0";
          };
        };

        functions = {
          _tmux_set_pane_command = ''
            [[ -n "$TMUX" && -n "$TMUX_PANE" ]] || return
            _tmux_update_seq=$(( _tmux_update_seq + 1 ))
            local tmux_shell_cmd="''${1%% *}"
            [[ "$tmux_shell_cmd" == *';' ]] && tmux_shell_cmd="''${tmux_shell_cmd%;}\\;"
            tmux set-option -p -q -t "$TMUX_PANE" @shell_cmd "$tmux_shell_cmd" ';' \
              set-option -p -q -t "$TMUX_PANE" @shell_seq "$_tmux_update_seq" 2>/dev/null
            "${scripts}/panes" "$TMUX_PANE" "" "$_tmux_update_seq" >/dev/null 2>&1 &!
          '';

          _tmux_clear_pane_command = ''
            [[ -n "$TMUX" && -n "$TMUX_PANE" ]] || return
            _tmux_update_seq=$(( _tmux_update_seq + 1 ))
            local tmux_pwd="$PWD" tmux_shell_name="''${ZSH_NAME:-zsh}"
            [[ "$tmux_pwd" == *';' ]] && tmux_pwd="''${tmux_pwd%;}\\;"
            [[ "$tmux_shell_name" == *';' ]] && tmux_shell_name="''${tmux_shell_name%;}\\;"
            tmux set-option -p -q -t "$TMUX_PANE" @shell_pwd "$tmux_pwd" ';' \
              set-option -p -q -t "$TMUX_PANE" @shell_cmd "$tmux_shell_name" ';' \
              set-option -p -q -t "$TMUX_PANE" @shell_seq "$_tmux_update_seq" 2>/dev/null
            "${scripts}/panes" "$TMUX_PANE" "" "$_tmux_update_seq" >/dev/null 2>&1 &!
          '';
        };

        hooks = {
          preexec = [
            {
              function = "_tmux_set_pane_command";
              tmuxOnly = true;
            }
          ];
          precmd = [
            {
              function = "_tmux_clear_pane_command";
              tmuxOnly = true;
            }
          ];
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
  };
}
