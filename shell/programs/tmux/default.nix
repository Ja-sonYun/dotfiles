{ pkgs
, ...
}:
{
  home.packages = with pkgs; [
    tmux
    pstree
    tmux-menu
  ];
  home.file.tmuxconf = {
    target = ".tmux.conf";
    source = toString ./tmux.conf;
  };
  home.sessionVariables.TMUX_CONFIG = toString ./config;

  home.shellAliases = {
    tm = toString ./config/scripts/tmux;
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
