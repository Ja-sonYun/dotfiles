{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.pi.agents.modelMap =
    lib.genAttrs
      [
        "xhigh"
        "high"
        "middle"
        "low"
      ]
      (_: {
        model = "${config.programs.pi.settings.defaultProvider}/${config.programs.pi.settings.defaultModel}";
        reasoning_effort = config.programs.pi.settings.defaultThinkingLevel;
      });

  programs.pi = {
    enable = true;
    # Keep Pi's execution tools available independently of the shared clients.
    extraPath = with pkgs; [
      nodejs_24
      sed-readonly
      aws-ro
      gh-ro
      jev
      redact
      dcf

      uv
      ruff
      mypy
      pyright

      cargo
      rustc
      clippy
      rustfmt
      rust-analyzer
      clang-tools
      go
      golangci-lint

      shellcheck
      shfmt
      prettier
      typescript
      eslint

      taplo
      stylua
      sqlfluff
      google-java-format
      ktfmt
      rubyfmt

      nixfmt
      statix

      terraform
    ];
    dev.extensionsSource = config.lib.file.mkRepoSource {
      path = "pkgs/pi/extensions";
      mode = "mutable";
    };

    settings = {
      extensions = {
        subagent.enable = true;
        permissions = {
          enable = true;
          summaries = {
            provider = "openai";
            model = "gpt-6-luna";
          };
        };
        redact.enable = true;
        message-lines.enable = true;
      };
      quietStartup = true;
      defaultProvider = "openai";
      defaultModel = "gpt-6-astra";
      defaultThinkingLevel = "high";
      defaultTools = [
        "+codemode"
        "+tool_search"
      ];
      enabledModels = [
        "lmp/**"
        "openai/**"
      ];
    };

    providers.lmp = {
      name = "LMP";
      fallbackModels = [ ];
      excludeOpenAIModels = true;
      defaults = {
        contextWindow = 256000;
        maxTokens = 32000;
      };
      imageModelMarkers = [
        "vision"
        "image"
      ];
      nonReasoningModelMarkers = [ "image" ];
    };
  };
}
