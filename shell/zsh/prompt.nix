_:
let
  cursorShape = "033[5 q"; # Use a blinking bar cursor to indicate normal mode
  PS1 =
    let
      promptTime = "[%D{%d/%m,%H:%M:%S}]";
      jobStatus = "%F{red}%(1j.%U•%j%u|.)%f";
      directory = "$(shorten-pwd)";
      symbol = " %F{green}$%f";
    in
    "${promptTime}${jobStatus}${directory}${symbol} ";
in
{
  programs.zsh-customize = {
    autoload = {
      history-search-end.flags = "-U";
      edit-command-line = { };
    };

    variables.PS1.value = PS1;

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
