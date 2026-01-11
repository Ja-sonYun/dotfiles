{ pkgs
, config
, agenix-secrets
, ...
}:
let
  opencodeConfig = {
    "$schema" = "https://opencode.ai/config.json";
    theme = "gihtub";
    model = "anthropic/claude-opus-4-5";
    autoupdate = false;
    share = "disabled";
    permission = {
      bash = "ask";
      edit = "ask";
    };

    keybinds = {
      messages_half_page_up = "ctrl+u";
      messages_half_page_down = "ctrl+d";
      app_exit = "ctrl+c,<leader>q";
      input_delete_to_line_start = "ctrl+shift+u";
    };

    provider = {
      anthropic = {
        models = {
          "claude-opus-4-5" = {
            options = {
              thinking = {
                type = "enabled";
                budgetTokens = 16000;
              };
            };
          };
        };
      };
      openai = {
        models = {
          "gpt-5.2-codex" = {
            options = {
              reasoningEffort = "high";
            };
          };
        };
      };
    };

    mcp = {
      context7 = {
        type = "local";
        command = [
          (toString (
            pkgs.writeShellScript "context7-mcp-wrapper" ''
              ${pkgs.context7}/bin/context7-mcp \
                --api-key "$(cat ${config.age.secrets.context7-api-key.path})"
            ''
          ))
        ];
      };

      playwright = {
        type = "local";
        command = [ "${pkgs.playwright-mcp}/bin/mcp-server-playwright" ];
        enabled = false;
      };

      chrome-devtools = {
        type = "local";
        command = [ "${pkgs.chrome-devtools-mcp}/bin/chrome-devtools-mcp" ];
        enabled = false;
      };

      aws-documentation = {
        type = "local";
        command = [ "${pkgs.aws-documentation}/bin/awslabs.aws-documentation-mcp-server" ];
        enabled = false;
      };

      terraform = {
        type = "local";
        command = [
          "${pkgs.terraform-mcp-server}/bin/terraform-mcp-server"
          "stdio"
        ];
        enabled = false;
      };

      github = {
        type = "local";
        command = [
          (toString (
            pkgs.writeShellScript "github-mcp-wrapper" ''
              export GITHUB_PERSONAL_ACCESS_TOKEN=$(cat ${config.age.secrets.github-token.path})
              exec docker run -i --rm \
                -e GITHUB_PERSONAL_ACCESS_TOKEN \
                ghcr.io/github/github-mcp-server
            ''
          ))
        ];
        enabled = false;
      };
    };
  };

  opencodeBundleSrc = "${agenix-secrets}/ai-bundle";

  opencodeWrapped = pkgs.symlinkJoin {
    name = "opencode-wrapped";
    paths = [ pkgs.opencode ];
    buildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/opencode \
        --prefix PATH : ${
          pkgs.lib.makeBinPath [
            pkgs.pyright
            pkgs.terraform
            pkgs.rust-analyzer
          ]
        }
    '';
  };
in
{
  home.packages = [ opencodeWrapped ];

  home.file = {
    ".config/opencode/opencode.json" = {
      text = builtins.toJSON opencodeConfig;
    };
    ".config/opencode/agent" = {
      source = "${opencodeBundleSrc}/prompts";
      recursive = true;
      force = true;
    };
    ".config/opencode/AGENTS.md" = {
      source = "${opencodeBundleSrc}/AGENTS.md";
      force = true;
    };
    ".config/opencode/skill" = {
      source = "${opencodeBundleSrc}/skills";
      recursive = true;
      force = true;
    };
  };
}
