{
  config,
  lib,
  ...
}:
{
  options.programs.tmux.extensions.sessionCleanup.enable =
    lib.mkEnableOption "tmux project session cleanup";

  config = lib.mkIf config.programs.tmux.extensions.sessionCleanup.enable {
    assertions = [
      {
        assertion = config.programs.zsh.enable && config.programs.zsh-customize.enable;
        message = "tmux session cleanup requires programs.zsh and programs.zsh-customize.";
      }
    ];

    programs.zsh-customize = {
      commands._tmux-session-cleanup-register = {
        description = "Register session for project cleanup";
        body = ''
          [[ -n "$TMUX" && -n "$TMUX_PANE" && -n "$1" ]] || exit 0
          session_id=$(tmux display-message -p -t "$TMUX_PANE" '#{session_id}') || exit 1
          project_root="''${PWD:A}"
          [[ "$project_root" == *';' ]] && project_root="''${project_root%;}\\;"
          tmux set-option -t "$session_id" @session_cleanup_root "$project_root" || exit 1
          tmux set-option -t "$session_id" @session_cleanup_label "$1"
        '';
      };

      blocks = [
        {
          functions = {
            _tmux_cleanup_confirm = ''
              local answer
              while true; do
                print -rn -- "Close $1? (y/n): "
                read -k1 answer </dev/tty || return 1
                print
                case "$answer" in
                  y|Y) return 0 ;;
                  n|N) return 1 ;;
                esac
              done
            '';

            _tmux_cleanup_sessions = ''
              [[ -o interactive && -t 0 && -n "$TMUX" && -n "$TMUX_PANE" && -z "$VIM" ]] || return 0
              local current_session session_id project_root label previous="$1" next="$2"
              current_session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null) || return 0
              [[ -z "$(tmux show-options -qv -t "$current_session" @session_cleanup_root 2>/dev/null)" ]] || return 0
              previous="''${previous:A}"
              [[ -z "$next" ]] || next="''${next:A}"

              while IFS= read -r session_id; do
                [[ "$session_id" != "$current_session" ]] || continue
                project_root=$(tmux show-options -qv -t "$session_id" @session_cleanup_root 2>/dev/null)
                [[ -n "$project_root" ]] || continue
                [[ "$previous" == "$project_root" || "$previous" == "''${project_root%/}/"* ]] || continue
                if [[ -n "$next" && ( "$next" == "$project_root" || "$next" == "''${project_root%/}/"* ) ]]; then
                  continue
                fi
                label=$(tmux show-options -qv -t "$session_id" @session_cleanup_label 2>/dev/null)
                if _tmux_cleanup_confirm "''${label:-$session_id}"; then
                  tmux kill-session -t "$session_id" 2>/dev/null
                fi
              done < <(tmux list-sessions -F '#{session_id}' 2>/dev/null)
              return 0
            '';

            _tmux_cleanup_chpwd = ''
              [[ -n "$OLDPWD" ]] || return 0
              _tmux_cleanup_sessions "$OLDPWD" "$PWD"
            '';

            _tmux_cleanup_zshexit = ''
              _tmux_cleanup_sessions "$PWD" ""
            '';
          };

          hooks = {
            chpwd = [
              {
                function = "_tmux_cleanup_chpwd";
                tmuxOnly = true;
              }
            ];
            zshexit = [
              {
                function = "_tmux_cleanup_zshexit";
                tmuxOnly = true;
              }
            ];
          };
        }
      ];
    };
  };
}
