_:
let
  cursorShape = "033[5 q"; # Use a blinking bar cursor to indicate normal mode
  PS1 =
    let
      promptTime = "[%D{%d/%m,%H:%M:%S}]";
      jobStatus = "%F{red}%(1j.%U•%j%u|.)%f";
      directory = "$(shorten-pwd)";
      gitStatus = "\${starship_git_prompt}";
      symbol = " %F{green}$%f";
    in
    "${promptTime}${jobStatus}${directory}${gitStatus}${symbol} ";
in
{
  programs.starship = {
    enable = true;
    enableBashIntegration = false;
    enableFishIntegration = false;
    enableZshIntegration = false;
    settings = {
      git_branch.format = "$branch";
      git_status = {
        format = "$all_status$ahead_behind";
        conflicted = "%F{red}=\${count}%F{8},";
        ahead = "%F{cyan}+\${count}%F{8},";
        behind = "%F{red}-\${count}%F{8},";
        diverged = "%F{cyan}+\${ahead_count}%F{8},%F{red}-\${behind_count}%F{8},";
        untracked = "%F{yellow}?\${count}%F{8},";
        stashed = "%F{magenta}*\${count}%F{8},";
        modified = "%F{yellow}!\${count}%F{8},";
        staged = "%F{green}@\${count}%F{8},";
        renamed = "%F{yellow}&\${count}%F{8},";
        deleted = "%F{yellow}-\${count}%F{8},";
      };
    };
  };

  programs.zsh-customize = {
    blocks = [
      {
        raw = "setopt prompt_subst";
        functions.update-starship-git-prompt = ''
          local git_branch="$(starship module git_branch)"
          local git_status="$(starship module git_status)"
          starship_git_prompt=""
          if [[ -n "$git_branch" ]]; then
            if (( ''${#git_branch} > 20 )); then
              git_branch="''${git_branch[1,5]}…''${git_branch[-14,-1]}"
            fi
            starship_git_prompt=" %F{cyan}''${git_branch//\%/%%}%f"
          fi
          if [[ -n "$git_status" ]]; then
            starship_git_prompt+=" %F{8}[''${git_status%,}%F{8}]%f"
          fi
        '';
        hooks.precmd = [ { function = "update-starship-git-prompt"; } ];
      }
    ];

    autoload = {
      history-search-end.flags = "-U";
      edit-command-line = { };
    };

    variables = {
      PS1.value = PS1;
      starship_git_prompt.value = "";
    };

    zle = {
      history-beginning-search-backward-end = {
        function = "history-search-end";
        bindkeys = [
          "^[[A"
          "^[OA"
        ];
      };
      history-beginning-search-forward-end = {
        function = "history-search-end";
        bindkeys = [
          "^[[B"
          "^[OB"
        ];
      };
      _edit-command-line-with-vim = {
        body = ''
          local EDITOR=vim
          local VISUAL=vim
          edit-command-line
          local ret=$?
          printf '\${cursorShape}'
          zle reset-prompt
          return $ret
        '';
        bindkeys = [ "^V" ];
      };
    };
  };
}
