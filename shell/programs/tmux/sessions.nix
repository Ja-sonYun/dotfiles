{ pkgs, ... }:
let
  closeHookTemplate = pkgs.writeText "tmux-close-hook-template" ''
    if [[ ! -z "$TMUX" ]]; then
        hooks_dir=$(find_hooks_dir "$OLDPWD")
        if [[ -n "$hooks_dir" ]]; then
            project_root=$(dirname "$hooks_dir")
            suffix="@command@_$(printf '%s' "$project_root" | sed -e 's#[/ .:]#_#g'):"
            git_name="git_root_$suffix"
            root_name="root_$suffix"
            tmux_session_name=$(tmux list-sessions | awk -F: -v git_pat="$git_name" -v root_pat="$root_name" \
                'index($0,git_pat) || index($0,root_pat) {print $1; exit}')
            if [[ -n "$tmux_session_name" ]]; then
                if ask_yes_no "Kill @command@"; then
                    tmux kill-session -t "$tmux_session_name" 2>/dev/null && \
                        echo "Closed tmux session for @command@_$(echo "$project_root" | tr '/' '_' | tr ' ' '_')" || \
                        echo "Failed to close tmux session for @command@_$(echo "$project_root" | tr '/' '_' | tr ' ' '_')"
                else
                    echo "Cancelled."
                fi
            fi
        fi
    fi
  '';
in
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
        hook_path=".hooks/on_exit/close_$command"
        mkdir -p .hooks/on_leave .hooks/on_exit

        hook_template=$(<${closeHookTemplate})
        print -r -- "''${hook_template//@command@/$command}" > "$hook_path"
        cp "$hook_path" ".hooks/on_leave/close_$command"
      '';
    };
  };
}
