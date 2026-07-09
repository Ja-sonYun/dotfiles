{
  pkgs,
  config,
  agenix-secrets,
  ...
}:
let
  claudeCode = pkgs.claude-code.override {
    extraPath = [
      pkgs.pyright
      pkgs.ruff
      pkgs.rustfmt
      pkgs.shfmt
      pkgs.prettier
      pkgs.terraform
      pkgs.rust-analyzer
      pkgs.clang-tools
    ];
  };

  claudeLmp = pkgs.writeShellScriptBin "claude-lmp" ''
    set -euo pipefail

    ai_address="$(${pkgs.coreutils}/bin/cat ${
      config.age.secrets."ai-address".path
    } 2>/dev/null || true)"
    export AI_ADDRESS="$ai_address"

    if [ -n "$ai_address" ]; then
      export ANTHROPIC_BASE_URL="''${ai_address%/}"
    fi

    export ANTHROPIC_API_KEY="$(${pkgs.coreutils}/bin/cat ${
      config.age.secrets."capi-key".path
    } 2>/dev/null || true)"
    export ANTHROPIC_CUSTOM_MODEL_OPTION="syn:large:text"
    export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="LMP text model"
    export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="LMP large text"
    export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="1"

    exec ${claudeCode}/bin/claude --model "syn:large:text" "$@"
  '';
in
{
  imports = [ "${agenix-secrets}/modules/ai-bundle/claude" ];

  programs.claude-code = {
    enable = true;
    package = claudeCode;
    enableMcpIntegration = true;
    chromeNativeHost.enable = true;

    mcpServers = { };

    settings = {
      alwaysThinkingEnabled = true;
      attribution = {
        commit = "";
        pr = "";
      };
      language = "korean";
      promptSuggestionEnabled = false;
      effortLevel = "high";
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

    desktopConfig = {
      mcpServers = removeAttrs config.programs.mcp.servers [ "grep_app" ];
    };
  };

  home.packages = [ claudeLmp ];
}
