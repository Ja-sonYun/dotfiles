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
}
