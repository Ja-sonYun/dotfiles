{
  pkgs,
  config,
  ...
}:
let
  statusLine = pkgs.writeShellScript "claude-statusline" ''
    input="$(${pkgs.coreutils}/bin/cat)"
    printf '%s' "$input" | AI_AGENT_CLIENT=Claude ${pkgs.python3}/bin/python \
      ${../ai-tools/hooks}/status.py --statusline ${pkgs.tmux}/bin/tmux || true
    printf '%s' "$input" | ${pkgs.jq}/bin/jq -rf ${./statusline.jq}
  '';
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
  programs.ai-agents.modelMap.claude = {
    xhigh = {
      model = "claude-fable-5-1";
      reasoning_effort = "xhigh";
    };
    high = {
      model = "claude-opus-5";
      reasoning_effort = "high";
    };
    middle = {
      model = "claude-sonnet-5";
      reasoning_effort = "low";
    };
    low = {
      model = "claude-haiku-4-5-20251001";
    };
  };

  programs.claude-code = {
    enable = true;
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
        command = "${statusLine}";
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
