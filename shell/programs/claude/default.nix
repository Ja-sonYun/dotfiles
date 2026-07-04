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
  };

  home.file = {
    ".claude/keybindings.json" = {
      text = builtins.toJSON {
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

    "Library/Application Support/Claude/claude_desktop_config.json" = {
      target = "Library/Application Support/Claude/claude_desktop_config.json";
      force = true;
      text = builtins.toJSON {
        mcpServers = removeAttrs config.programs.mcp.servers [ "grep_app" ];
      };
    };
  };
}
