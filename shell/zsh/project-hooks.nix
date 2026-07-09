_: {
  programs.zsh-customize.blocks = [
    {
      variables = {
        _hook_version.value = "1";
        _tmux_update_seq = {
          flags = "-gi";
          value = "0";
        };
      };

      raw = ''
        set -o ignoreeof
        setopt prompt_subst

        export SHELL_CD_REQUEST_FILE="''${TMPDIR:-/tmp}/shell-cd-$UID-$$"
        rm -f "$SHELL_CD_REQUEST_FILE" 2>/dev/null || true
      '';

      functions = {
        _shell_apply_cd_request = ''
          local dir
          [[ -f "$SHELL_CD_REQUEST_FILE" ]] || return
          IFS= read -r dir < "$SHELL_CD_REQUEST_FILE"
          rm -f "$SHELL_CD_REQUEST_FILE"
          [[ -d "$dir" ]] && cd "$dir"
        '';

        _tmux_set_pane_command = ''
          [[ -n "$TMUX" && -n "$TMUX_PANE" ]] || return
          [[ -n "$TMUX_CONFIG" ]] || return
          _tmux_update_seq=$(( _tmux_update_seq + 1 ))
          tmux set-option -p -q -t "$TMUX_PANE" @shell_cmd "''${1%% *}" ';' \
            set-option -p -q -t "$TMUX_PANE" @shell_seq "$_tmux_update_seq" 2>/dev/null
          "$TMUX_CONFIG/scripts/shell-session/update" "$TMUX_PANE" "$_tmux_update_seq" >/dev/null 2>&1 &!
        '';

        _tmux_clear_pane_command = ''
          [[ -n "$TMUX" && -n "$TMUX_PANE" ]] || return
          [[ -n "$TMUX_CONFIG" ]] || return
          _tmux_update_seq=$(( _tmux_update_seq + 1 ))
          tmux set-option -p -q -t "$TMUX_PANE" @shell_pwd "$PWD" ';' \
            set-option -p -q -t "$TMUX_PANE" @shell_cmd "''${ZSH_NAME:-zsh}" ';' \
            set-option -p -q -t "$TMUX_PANE" @shell_seq "$_tmux_update_seq" 2>/dev/null
          "$TMUX_CONFIG/scripts/shell-session/update" "$TMUX_PANE" "$_tmux_update_seq" >/dev/null 2>&1 &!
          "$TMUX_CONFIG/scripts/agent-session/counts" >/dev/null 2>&1 &!
        '';

        find_hooks_dir = ''
          local dir="$1"
          while [[ "$dir" != "/" ]]; do
              if [[ -d "$dir/.hooks" ]]; then
                  echo "$dir/.hooks"
                  return 0
              fi
              dir=$(dirname "$dir")
          done
          return 1
        '';

        _run_hook_file = ''
          local file="$1" base="''${1##*/}"
          if [[ "$base" == close_* ]]; then
              local ver; ver=$(sed -n 's/^# hook-version: //p' "$file" 2>/dev/null | head -1)
              if [[ "''${ver:-0}" -lt $_hook_version ]]; then rm -f "$file"; return; fi
          fi
          source "$file"
        '';

        _project_hooks_chpwd = ''
          [[ -n "$VIM" ]] && return
          local old_hooks=""
          local new_hooks=""

          # Find hooks directories
          [[ -n "$OLDPWD" ]] && old_hooks=$(find_hooks_dir "$OLDPWD")
          new_hooks=$(find_hooks_dir "$PWD")

          # Only run hooks if we're changing between different hook contexts
          if [[ "$old_hooks" != "$new_hooks" ]]; then
              # Run on_leave hooks
              if [[ -n "$old_hooks" && -d "$old_hooks/on_leave" ]]; then
                  setopt localoptions nullglob
                  for file in "$old_hooks/on_leave/"*; do
                      if [[ -f "$file" ]]; then
                          _run_hook_file "$file"
                      fi
                  done
              fi
              # Run on_enter hooks
              if [[ -n "$new_hooks" && -d "$new_hooks/on_enter" ]]; then
                  setopt localoptions nullglob
                  for file in "$new_hooks/on_enter/"*; do
                      if [[ -f "$file" ]]; then
                          _run_hook_file "$file"
                      fi
                  done
              fi
          fi
        '';

        _project_hooks_zshexit = ''
          [[ -n "$VIM" ]] && return
          local current_hooks=$(find_hooks_dir "$PWD")

          if [[ -n "$current_hooks" && -d "$current_hooks/on_exit" ]]; then
              export OLDPWD="$PWD"
              setopt localoptions nullglob
              for file in "$current_hooks/on_exit/"*; do
                  if [[ -f "$file" ]]; then
                      _run_hook_file "$file"
                  fi
              done
          fi
        '';

        ask_yes_no = ''
          local prompt="''${1:-Continue}"
          local answer

          while true; do
              echo -n "$prompt (y/n): "
              read -k1 answer
              echo
              if [[ $answer == "y" || $answer == "Y" ]]; then
                  return 0
              elif [[ $answer == "n" || $answer == "N" ]]; then
                  return 1
              else
                  echo "Please enter y or n."
              fi
          done
        '';

        chpwd-hook-init = ''
          mkdir -p .hooks/on_enter .hooks/on_leave
          echo "echo 'You have entered $(basename \"$PWD\")'" > .hooks/on_enter/enter.sh
          echo "echo 'You have left $(basename \"$PWD\")'" > .hooks/on_leave/leave.sh
          echo "echo 'You have exited $(basename \"$PWD\")'" > .hooks/on_exit/exit.sh
        '';
      };

      hooks = {
        preexec = [ "_tmux_set_pane_command" ];
        precmd = [
          "_shell_apply_cd_request"
          "_tmux_clear_pane_command"
        ];
        chpwd = [ "_project_hooks_chpwd" ];
        zshexit = [ "_project_hooks_zshexit" ];
      };
    }
  ];
}
