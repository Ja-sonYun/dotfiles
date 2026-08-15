{
  agenix-secrets,
  claudePackage,
  home-manager,
  testPackage,
  testPkgs,
  ...
}:
let
  inherit (testPkgs) lib;
  configuration = home-manager.lib.homeManagerConfiguration {
    pkgs = testPkgs;
    extraSpecialArgs.homeManagerSrc = home-manager.outPath;
    modules = [
      ../../../../modules/programs/ai-agents
      ../../../../modules/programs/claude
      ../../../../modules/programs/codex
      ../../../../modules/programs/pi
      agenix-secrets.homeManagerModules.ai-agents
      (
        { lib, pkgs, ... }:
        {
          options.programs.tmux.agentStatusScript = lib.mkOption { type = lib.types.str; };

          config = {
            home = {
              username = "test-user";
              homeDirectory = "/home/test-user";
              stateVersion = "26.05";
            };

            programs = {
              ai-agents.enable = lib.mkForce false;
              claude-code = {
                enable = true;
                package = claudePackage;
              };
              codex = {
                enable = true;
                package = testPackage "codex";
              };
              tmux.agentStatusScript = toString (pkgs.writeShellScript "test-agent-status" "exit 0");
            };
          };
        }
      )
    ];
  };
  home = configuration.config.home;
  homeFiles = import ../../../lib/home-files.nix {
    inherit lib home;
    pkgs = testPkgs;
  };
  marketplaceRoot = testPkgs.ai-marketplaces.agent-toolkit-for-aws;
  pluginVersion = "1.1.0";
  generatedFiles = {
    Claude = homeFiles.generated [
      ".claude/settings.json"
      ".claude/plugins/known_marketplaces.json"
    ];
    Codex = builtins.sort builtins.lessThan (
      homeFiles.generated [ ".codex/plugins/cache" ]
      ++ lib.optional (lib.hasInfix "/.codex/config.toml" home.activation.codexConfigMerge.data) "~/.codex/config.toml"
    );
  };
  awsCorePlugin = marketplaceRoot + "/plugins/aws-core";
  claudeSeed = home.sessionVariables.CLAUDE_CODE_PLUGIN_SEED_DIR;
  knownMarketplace = {
    source = {
      source = "directory";
      path = toString marketplaceRoot;
    };
    installLocation = toString marketplaceRoot;
    lastUpdated = "1970-01-01T00:00:00Z";
  };
  awsMcp = {
    command = "uvx";
    args = [
      "mcp-proxy-for-aws@1.6.4"
      "https://aws-mcp.us-east-1.api.aws/mcp"
      "--skip-auth"
      "--metadata"
      "INSTALL_SOURCE=agent-toolkit-core"
    ];
  };
  actual = {
    inherit generatedFiles;
    files = {
      "marketplace/.agents/plugins/marketplace.json" =
        "${marketplaceRoot}/.agents/plugins/marketplace.json";
      "marketplace/.claude-plugin/marketplace.json" =
        "${marketplaceRoot}/.claude-plugin/marketplace.json";
      "marketplace/plugins/aws-core/.codex-plugin/plugin.json" =
        "${awsCorePlugin}/.codex-plugin/plugin.json";
      "marketplace/plugins/aws-core/.claude-plugin/plugin.json" =
        "${awsCorePlugin}/.claude-plugin/plugin.json";
      "marketplace/plugins/aws-core/.mcp.json" = "${awsCorePlugin}/.mcp.json";
      "~/.codex/config.toml".environment = "MARKETPLACE_CODEX_CONFIG";
      "~/.claude/settings.json" = homeFiles.materialized ".claude/settings.json";
      "~/.claude/plugins/known_marketplaces.json" =
        homeFiles.materialized ".claude/plugins/known_marketplaces.json";
      "$CLAUDE_CODE_PLUGIN_SEED_DIR/known_marketplaces.json" = "${claudeSeed}/known_marketplaces.json";
      "$CLAUDE_CODE_PLUGIN_SEED_DIR/marketplaces/agent-toolkit-for-aws/.claude-plugin/marketplace.json" =
        "${claudeSeed}/marketplaces/agent-toolkit-for-aws/.claude-plugin/marketplace.json";
      "$CLAUDE_CODE_PLUGIN_SEED_DIR/cache/agent-toolkit-for-aws/aws-core/${pluginVersion}/.mcp.json" =
        "${claudeSeed}/cache/agent-toolkit-for-aws/aws-core/${pluginVersion}/.mcp.json";
    };
  };
  expected = {
    generatedFiles = {
      Claude = [
        "~/.claude/plugins/known_marketplaces.json"
        "~/.claude/settings.json"
      ];
      Codex = [ "~/.codex/config.toml" ];
    };
    files = {
      "marketplace/.agents/plugins/marketplace.json".json.contains = {
        name = "agent-toolkit-for-aws";
        plugins = [
          {
            name = "aws-core";
            source = {
              source = "local";
              path = "./plugins/aws-core";
            };
          }
        ];
      };
      "marketplace/.claude-plugin/marketplace.json".json.contains = {
        name = "agent-toolkit-for-aws";
        plugins = [
          {
            name = "aws-core";
            source = "./plugins/aws-core";
            version = pluginVersion;
          }
        ];
      };
      "marketplace/plugins/aws-core/.codex-plugin/plugin.json".json.contains = {
        name = "aws-core";
        version = pluginVersion;
        mcpServers = "./.mcp.json";
      };
      "marketplace/plugins/aws-core/.claude-plugin/plugin.json".json.contains = {
        name = "aws-core";
        version = pluginVersion;
      };
      "marketplace/plugins/aws-core/.mcp.json".json.at.mcpServers.at.aws-mcp.equals = awsMcp;
      "~/.codex/config.toml".toml.contains = {
        features.plugins = true;
        marketplaces.agent-toolkit-for-aws = {
          source_type = "local";
          source = toString marketplaceRoot;
        };
        plugins."aws-core@agent-toolkit-for-aws" = {
          enabled = true;
          mcp_servers.aws-mcp.default_tools_approval_mode = "writes";
        };
      };
      "~/.claude/settings.json".json.contains = {
        enabledPlugins."aws-core@agent-toolkit-for-aws" = true;
        extraKnownMarketplaces.agent-toolkit-for-aws.source = {
          source = "directory";
          path = toString marketplaceRoot;
        };
      };
      "~/.claude/plugins/known_marketplaces.json".json.contains.agent-toolkit-for-aws = knownMarketplace;
      "$CLAUDE_CODE_PLUGIN_SEED_DIR/known_marketplaces.json".json.contains.agent-toolkit-for-aws =
        knownMarketplace;
      "$CLAUDE_CODE_PLUGIN_SEED_DIR/marketplaces/agent-toolkit-for-aws/.claude-plugin/marketplace.json".sameAs =
        marketplaceRoot + "/.claude-plugin/marketplace.json";
      "$CLAUDE_CODE_PLUGIN_SEED_DIR/cache/agent-toolkit-for-aws/aws-core/${pluginVersion}/.mcp.json".sameAs =
        awsCorePlugin + "/.mcp.json";
    };
  };
in
{
  inherit actual configuration expected;
}
