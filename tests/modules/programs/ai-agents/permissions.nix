{
  aiAgentModules,
  homeFilesFor,
  managedFragment,
  mkConfiguration,
  testPkgs,
  ...
}:
let
  inherit (testPkgs) lib;
  permissionPolicy = {
    commands.rules = [
      {
        prefix = [
          "git"
          "status"
        ];
        decision = "allow";
      }
    ];
    files.rules = [
      {
        path = "docs/**";
        read = "allow";
        write = "deny";
      }
      {
        path = "**/.env";
        read = "deny";
        write = "deny";
      }
      {
        path = "**/*.env.*";
        excludes = [ "**/.env.example" ];
        read = "deny";
        write = "deny";
      }
      {
        path = "**/.env.example";
        read = "allow";
        write = "allow";
      }
    ];
    mcp = {
      blocked.default = "deny";
      local-docs.default = "allow";
      remote-docs.default = "ask";
      github.tools.get_file_contents = "allow";
    };
  };
  configuration = mkConfiguration {
    featureModules = [
      aiAgentModules.enable
      aiAgentModules.hooks
      aiAgentModules.permissions
    ];
    module.programs.ai-agents = {
      enable = true;
      permissions = permissionPolicy;
    };
  };
  home = configuration.config.home;
  homeFiles = homeFilesFor configuration;
  actual = {
    generatedFiles = {
      Claude = homeFiles.generated [ ".claude/settings.json" ];
      Codex = builtins.sort builtins.lessThan (
        homeFiles.generated [ ".codex/rules/managed.rules" ]
        ++ lib.optional (lib.hasInfix "/.codex/config.toml" home.activation.codexConfigMerge.data) "~/.codex/config.toml"
      );
    };
    files = {
      "~/.claude/settings.json" = homeFiles.materialized ".claude/settings.json";
      "~/.codex/config.toml" = managedFragment configuration;
      "~/.codex/rules/managed.rules" = homeFiles.materialized ".codex/rules/managed.rules";
    };
  };
  expected = {
    generatedFiles = {
      Claude = [ "~/.claude/settings.json" ];
      Codex = [
        "~/.codex/config.toml"
        "~/.codex/rules/managed.rules"
      ];
    };
    files = {
      "~/.claude/settings.json".json.at = {
        permissions.equals = {
          allow = [
            "Bash(git status)"
            "Bash(git status *)"
            "mcp__github__get_file_contents"
            "mcp__plugin_hm_github__get_file_contents"
            "mcp__local-docs__*"
            "mcp__plugin_hm_local-docs__*"
          ];
          ask = [ ];
          deny = [ "Read(./**/.env)" ];
        };
        hooks.keys = [ "PreToolUse" ];
      };
      "~/.codex/config.toml".toml = {
        contains.mcp_servers = {
          blocked = {
            enabled = false;
            enabled_tools = [ ];
            default_tools_approval_mode = "prompt";
          };
          github.tools.get_file_contents = {
            enabled = true;
            approval_mode = "approve";
          };
          local-docs.default_tools_approval_mode = "approve";
          remote-docs.default_tools_approval_mode = "prompt";
        };
        at.hooks.keys = [ "PreToolUse" ];
      };
      "~/.codex/rules/managed.rules".text = ''
        prefix_rule(pattern = ["git","status"], decision = "allow")
      '';
    };
  };
in
{
  name = "AI agents permissions";
  inherit actual expected;
}
