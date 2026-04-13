{ pkgs
, config
, agenix-secrets
, ...
}:
let
  aiBundle = import "${agenix-secrets}/ai-bundle.nix" { inherit pkgs; };

  claudeMcpServers = {
    codex = {
      type = "stdio";
      command = "${config.home.profileDirectory}/bin/codex";
      args = [ "mcp-server" ];
      env = { };
    };
  };

  claudeCodeWrapped = pkgs.symlinkJoin {
    name = "claude-code-wrapped";
    paths = [ pkgs.claude-code ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      mv $out/bin/claude $out/bin/claude-real

      wrapProgram $out/bin/claude-real \
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
        } \
        --set DISABLE_BUG_COMMAND         1 \
        --set DISABLE_INSTALLATION_CHECKS 1 \
        --set DISABLE_AUTOUPDATER         1 \
        --set DISABLE_ERROR_REPORTING     1 \
        --set DISABLE_COST_WARNINGS       1

      cat > $out/bin/claude <<'EOF'
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      profile="oauth"
      args=()

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --profile)
            if [ "$#" -lt 2 ]; then
              echo "Error: --profile requires a value (oauth|custom)" >&2
              exit 1
            fi
            profile="$2"
            shift 2
            ;;
          --profile=*)
            profile="''${1#--profile=}"
            shift
            ;;
          --)
            args+=("$1")
            shift
            while [ "$#" -gt 0 ]; do
              args+=("$1")
              shift
            done
            ;;
          *)
            args+=("$1")
            shift
            ;;
        esac
      done

      case "$profile" in
        oauth)
          unset ANTHROPIC_BASE_URL || true
          unset ANTHROPIC_AUTH_TOKEN || true
          unset ANTHROPIC_API_KEY || true
          unset ANTHROPIC_DEFAULT_SONNET_MODEL || true
          unset ANTHROPIC_DEFAULT_OPUS_MODEL || true
          unset ANTHROPIC_DEFAULT_HAIKU_MODEL || true
          ;;
        custom)
          export ANTHROPIC_BASE_URL="https://lmp.test0.zip"
          export ANTHROPIC_AUTH_TOKEN="$(cat ${config.age.secrets.capi-key.path})"
          export ANTHROPIC_DEFAULT_OPUS_MODEL="gpt-5.3-codex(xhigh)"
          export ANTHROPIC_DEFAULT_SONNET_MODEL="gpt-5.3-codex(high)"
          export ANTHROPIC_DEFAULT_HAIKU_MODEL="gpt-5.3-codex-spark"
          ;;
        *)
          echo "Error: invalid profile '$profile'. Use 'oauth' or 'custom'." >&2
          exit 1
          ;;
      esac

      exec "$(dirname "$0")/claude-real" "''${args[@]}"
      EOF

      chmod +x $out/bin/claude
    '';
  };
in
{
  programs.claude-code = {
    enable = true;
    package = claudeCodeWrapped;
    enableMcpIntegration = true;

    mcpServers = claudeMcpServers;

    settings = {
      permissions = {
        allow = [
          "WebSearch"
          "WebFetch(domain:*)"
          "Read(**)"
          "Bash(git status *)"
          "Bash(git diff *)"
          "Bash(git log *)"
          "Bash(git show *)"
          "Bash(ls *)"
          "Bash(cat *)"
          "Bash(rg *)"
          "Bash(find *)"
          "Bash(grep *)"
          "Bash(tail *)"
          "Bash(head *)"
          "Bash(echo *)"
          "Bash(jq *)"
          "Bash(yq *)"
          "Bash(wc *)"
          "Bash(sort *)"
          "Bash(uniq *)"
          "Bash(diff *)"
          "Bash(file *)"
          "Bash(which *)"
          "Bash(stat *)"
          "Bash(du *)"
          "Bash(tree *)"
          "Bash(realpath *)"
          "Bash(dirname *)"
          "Bash(basename *)"
          "Bash(make *)"
          "Bash(nix log *)"
          "Bash(nix flake lock *)"
          "Skill(diagram *)"
          "Skill(python *)"
          "mcp__plugin_claude-code-home-manager_codex__*"
          "mcp__plugin_claude-code-home-manager_aws-documentation__*"
          "mcp__plugin_claude-code-home-manager_context7__*"
          "mcp__plugin_claude-code-home-manager_grep_app__*"
          "mcp__plugin_claude-code-home-manager_websearch__*"
        ];
        deny = [
          "Read(./.env)"
          "Read(./.env.*)"
        ];
      };
      alwaysThinkingEnabled = true;
      hooks = {
        Notification = [
          {
            matcher = "permission_prompt";
            hooks = [
              {
                type = "command";
                command = "${pkgs.terminal-notifier}/bin/terminal-notifier -title 'cc' -message 'Permission requested' -sound Funk";
              }
            ];
          }
          {
            matcher = "idle_prompt";
            hooks = [
              {
                type = "command";
                command = "${pkgs.terminal-notifier}/bin/terminal-notifier -title 'cci' -message 'Awaiting your input' -sound Funk";
              }
            ];
          }
        ];
      };
      attribution = {
        commit = "";
        pr = "";
      };
      language = "korean";
      enabledPlugins = {
        "pyright-lsp@claude-plugins-official" = true;
      };
      promptSuggestionEnabled = false;
      effortLevel = "high";
    };

    context = aiBundle.agentsMdSrc;
    agentsDir = "${aiBundle.agentsSrc}";
    skills = "${aiBundle.skillsSrc}";
  };

  home.file = {
    "Library/Application Support/Claude/claude_desktop_config.json" = {
      target = "Library/Application Support/Claude/claude_desktop_config.json";
      force = true;
      text = builtins.toJSON {
        mcpServers = removeAttrs config.programs.mcp.servers [ "grep_app" ] // claudeMcpServers;
      };
    };
  };
}
