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
    "*" = "ask";
    bash = {
      "*" = "ask";
      "git status" = "allow";
    };
    external_directory."*" = "ask";
    mcp = {
      "*" = "ask";
      blocked = "deny";
      local-docs = "allow";
      remote-docs = "ask";
    };
    mcp_readonly_tools.github = [ "get_file_contents" ];
    path = {
      "*" = "ask";
      "/private/tmp" = "allow";
      "/private/tmp/**" = "allow";
      "/tmp" = "allow";
      "/tmp/**" = "allow";
      docs = "read";
    };
    read = "allow";
    skill."*" = "allow";
    web_fetch = "deny";
    web_search = "allow";
    write = "deny";
  };
  configuration = mkConfiguration {
    featureModules = [
      aiAgentModules.core
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
      "~/.claude/settings.json".json.contains.permissions = {
        allow = [
          "Read(**)"
          "WebSearch"
          "Read(docs)"
          "Edit(//private/tmp)"
          "Edit(//private/tmp/**)"
          "Edit(//tmp)"
          "Edit(//tmp/**)"
          "Skill"
          "Bash(git status)"
          "mcp__plugin_hm_local-docs__*"
          "mcp__plugin_hm_github__get_file_contents"
        ];
        ask = [ ];
        deny = [
          "Edit(docs)"
          "mcp__plugin_hm_blocked__*"
          "Write"
          "WebFetch(domain:*)"
        ];
      };
      "~/.codex/config.toml".toml.contains = {
        default_permissions = "managed";
        permissions.managed = {
          extends = ":workspace";
          filesystem = {
            "/private/tmp" = "write";
            "/private/tmp/**" = "write";
            "/tmp" = "write";
            "/tmp/**" = "write";
            ":workspace_roots".docs = "read";
          };
          network.enabled = true;
        };
        mcp_servers = {
          github.default_tools_approval_mode = "writes";
          local-docs.default_tools_approval_mode = "approve";
        };
      };
      "~/.codex/rules/managed.rules".text = ''
        prefix_rule(pattern = ["git", "status"], decision = "allow")
      '';
    };
  };
in
{
  name = "AI agents permissions";
  inherit actual expected;
}
