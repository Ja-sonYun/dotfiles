{
  programs.tmux-customize = {
    sessions = {
      main = {
        group = "normal";
        environment = {
          MAIN = "1";
          DEFAULT = "1";
        };
        unicode = true;
      };
    };

    launcher = {
      enable = true;
      startSessions = [ "main" ];
      attach = "main";
    };
  };

  programs.zsh-customize.blocks = [
    {
      functions.ask_yes_no = ''
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
    }
  ];

  programs.zsh-customize.commands = {
    _gen-close-hook = {
      description = "Generate a tmux close hook for a given command";
      body = ''
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
