{ pkgs, ... }:
{
  programs.zsh-customize.zle = {
    _generate-shell-command-with-openai = {
      body =
        let
          generator = pkgs.uv.asPackage {
            name = "generate-shell-command-with-openai";
            root = ./.;
            entrypoint = "generate_command:main";
          };
        in
        ''
          zle -R "[Generating shell command with OpenAI...]"

          if [[ -z ''$BUFFER ]]; then
            zle -R "[No input provided.]"
            return
          fi

          local current_input="''${LBUFFER}''${RBUFFER}"
          local generated_text
          if ! generated_text=$(${generator}/bin/generate-shell-command-with-openai ''$current_input); then
            zle -R "[Failed to generate command.]"
            return
          fi

          LBUFFER="''${generated_text}"
          RBUFFER=""
        '';
      bindkeys = [
        "^X^m"
        "^Xm"
      ];
    };
  };
}
