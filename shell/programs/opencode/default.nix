{ pkgs
, config
, agenix-secrets
, ...
}:
let
  opencodeConfig = {
    "$schema" = "https://opencode.ai/config.json";
    theme = "gihtub";
    model = "openai/gpt-5.2-codex";
    share = "disabled";
    default_agent = "plan";

    autoupdate = false;
    snapshot = false;

    compaction = {
      auto = true;
      prune = true;
    };

    permission = {
      bash = {
        "*" = "ask";
        # file operations (read-only)
        "ls *" = "allow";
        "tree *" = "allow";
        "cat *" = "allow";
        "head *" = "allow";
        "tail *" = "allow";
        "wc *" = "allow";
        "file *" = "allow";
        "stat *" = "allow";
        "diff *" = "allow";
        # search
        "rg *" = "allow";
        "fd *" = "allow";
        "find *" = "allow";
        "grep *" = "allow";
        "which *" = "allow";
        "command -v *" = "allow";
        "type *" = "allow";
        # system
        "uname *" = "allow";
        # info
        "pwd" = "allow";
        "echo *" = "allow";
        # git (read-only)
        "git status*" = "allow";
        "git log*" = "allow";
        "git diff*" = "allow";
        "git branch*" = "allow";
        "git show*" = "allow";
        "git rev-parse*" = "allow";
        "git remote*" = "allow";
        "git push*" = "deny";
        "git commit*" = "deny";
        "git checkout*" = "deny";
        "git merge*" = "deny";
        "git reset*" = "deny";
        "git pull*" = "deny";
        # github cli (read-only)
        "gh repo view*" = "allow";
        "gh pr list*" = "allow";
        "gh pr view*" = "allow";
        "gh pr diff*" = "allow";
        "gh issue list*" = "allow";
        "gh issue view*" = "allow";
        "gh search *" = "allow";
        "gh status*" = "allow";
        "gh auth status*" = "allow";
        # terraform
        "terraform apply*" = "deny";
      };
      edit = "ask";
    };

    keybinds = {
      messages_half_page_up = "ctrl+u";
      messages_half_page_down = "ctrl+d";
      app_exit = "ctrl+c,<leader>q";
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

      websearch = {
        type = "remote";
        url = "https://mcp.exa.ai/mcp";
      };

      grep_app = {
        type = "remote";
        url = "https://mcp.grep.app";
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
            pkgs.ruff
            pkgs.rustfmt
            pkgs.shfmt
            pkgs.prettier
            pkgs.terraform
            pkgs.rust-analyzer
            pkgs.clang-tools
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
    ".config/opencode/AGENTS.md" = {
      source = "${opencodeBundleSrc}/AGENTS.md";
    };
    ".config/opencode/agent" = {
      source = "${opencodeBundleSrc}/agents";
      recursive = true;
    };
    ".config/opencode/skill" = {
      source = "${opencodeBundleSrc}/skills";
      recursive = true;
    };
    ".config/opencode/plugin/md-table.ts" = {
      source = ./plugins/md-table.ts;
    };
    ".config/opencode/plugin/notification.js" = {
      source = ./plugins/notification.js;
    };
  };
}
