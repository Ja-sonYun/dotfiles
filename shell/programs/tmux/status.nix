{
  programs.tmux-customize = {
    enable = true;
    defaultGroup = "normal";

    segments = {
      space = "printf ' '";

      prompt = ''printf '#[fg=red]X #[fg=default]%s>> ' "''${USER:-$(whoami)}"'';

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
            "git"
            "pwd"
          ];
        };
        window = {
          format = "#I:#{?#{@panes},#{@panes},#W}#[push-default]#{@agent_counts_display}#[pop-default]";
          currentFormat = "#[fg=white]#[bg=green]▌#[default]#[bg=green]#I:#{?#{@panes},#{@panes},#W}#[push-default]#{@agent_counts_display}#[pop-default]#[default]#[fg=white]#[bg=green]▐#[default]";
        };
      };

    };
  };
}
