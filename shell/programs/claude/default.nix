{
  pkgs,
  config,
  ...
}:
let
  claudeLmp = pkgs.writeShellScriptBin "claude-lmp" ''
    set -euo pipefail

    llm_domain="$(${pkgs.coreutils}/bin/cat ${
      config.age.secrets."llm-domain".path
    } 2>/dev/null || true)"
    export LLM_DOMAIN="$llm_domain"

    if [ -n "$llm_domain" ]; then
      export ANTHROPIC_BASE_URL="''${llm_domain%/}"
    fi

    export ANTHROPIC_API_KEY="$(${pkgs.coreutils}/bin/cat ${
      config.age.secrets."capi-key".path
    } 2>/dev/null || true)"
    export ANTHROPIC_CUSTOM_MODEL_OPTION="syn:large:text"
    export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="LMP text model"
    export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="LMP large text"
    export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="1"

    exec ${config.programs.claude-code.finalPackage}/bin/claude --model "syn:large:text" "$@"
  '';
in
{
  programs.claude-code = {
    enable = true;
    extraPath = [
      pkgs.aws-ro
      pkgs.gh-ro
      pkgs.uv
      pkgs.pyright
      pkgs.ruff
      pkgs.rustfmt
      pkgs.shfmt
      pkgs.prettier
      pkgs.terraform
      pkgs.rust-analyzer
      pkgs.clang-tools
    ];
    chromeNativeHost.enable = true;

    settings = {
      alwaysThinkingEnabled = true;
      attribution = {
        commit = "";
        pr = "";
      };
      language = "korean";
      promptSuggestionEnabled = false;
      effortLevel = "high";
      statusLine = {
        type = "command";
        command = "${pkgs.jq}/bin/jq -rf ${./statusline.jq}";
      };
    };

    keybindings = {
      bindings = [
        {
          context = "Scroll";
          bindings = {
            "ctrl+u" = "scroll:halfPageUp";
            "ctrl+n" = "scroll:halfPageDown";
          };
        }
      ];
    };
  };

  home.packages = [ claudeLmp ];
}
