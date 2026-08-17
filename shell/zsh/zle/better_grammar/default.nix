{ pkgs, ... }:
{
  programs.zsh-customize.zle = {
    _fix-grammar-with-openai = {
      body =
        let
          betterGrammar = pkgs.uv.asPackage {
            name = "fix-grammar-with-openai";
            root = ./.;
            entrypoint = "better_grammar:main";
          };
        in
        ''
          zle -R "[Fixing grammar with OpenAI...]"

          if [[ -z ''$BUFFER ]]; then
            zle -R "[No input provided.]"
            return
          fi

          local current_input="''${LBUFFER}''${RBUFFER}"
          local fixed_text=''$(${betterGrammar}/bin/fix-grammar-with-openai ''$current_input)

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
