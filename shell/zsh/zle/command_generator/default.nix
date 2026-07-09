{ pkgs, ... }:
{
  programs.zsh-customize.zle = {
    _generate-shell-command-with-openai = {
      body =
        let
          pythonEnv = pkgs.python312.withPackages (
            ps: with ps; [
              openai
              pydantic
            ]
          );
          python = "${pythonEnv}/bin/python";
          generator_py = toString ./generate_command.py;
        in
        ''
          zle -R "[Generating shell command with OpenAI...]"

          if [[ -z ''$BUFFER ]]; then
            zle -R "[No input provided.]"
            return
          fi

          local current_input="''${LBUFFER}''${RBUFFER}"
          local generated_text
          if ! generated_text=$(${python} ${generator_py} ''$current_input); then
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
