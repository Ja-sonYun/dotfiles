_: {
  programs.zsh-customize.blocks = [
    {
      functions = {
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
                          source "$file"
                      fi
                  done
              fi
              # Run on_enter hooks
              if [[ -n "$new_hooks" && -d "$new_hooks/on_enter" ]]; then
                  setopt localoptions nullglob
                  for file in "$new_hooks/on_enter/"*; do
                      if [[ -f "$file" ]]; then
                          source "$file"
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
                      source "$file"
                  fi
              done
          fi
        '';

        chpwd-hook-init = ''
          mkdir -p .hooks/on_enter .hooks/on_leave
          echo "echo 'You have entered $(basename \"$PWD\")'" > .hooks/on_enter/enter.sh
          echo "echo 'You have left $(basename \"$PWD\")'" > .hooks/on_leave/leave.sh
          echo "echo 'You have exited $(basename \"$PWD\")'" > .hooks/on_exit/exit.sh
        '';
      };

      hooks = {
        chpwd = [ "_project_hooks_chpwd" ];
        zshexit = [ "_project_hooks_zshexit" ];
      };
    }
  ];
}
