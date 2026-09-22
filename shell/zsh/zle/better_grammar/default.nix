{ pkgs, ... }:
{
  programs.zsh-customize.zle = {
    _fix-grammar-with-openai = {
      body = ''
        zle -R "[Fixing grammar with OpenAI...]"

        if [[ -z ''$BUFFER ]]; then
          zle -R "[No input provided.]"
          return
        fi

        local current_input="''${LBUFFER}''${RBUFFER}"
        local fixed_text
        if ! fixed_text="$(${pkgs.shell-assistant}/bin/fix-grammar-with-openai "$current_input")" || [[ -z "$fixed_text" ]]; then
          zle -R "[Grammar correction failed; input preserved.]"
          return 1
        fi

        LBUFFER="''${fixed_text}"
        RBUFFER=""
      '';
      bindkeys = [
        "^X^o"
        "^Xo"
      ];
    };
  };
}
