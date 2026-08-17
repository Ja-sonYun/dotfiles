{
  claudePackage,
  home-manager,
  testPackage,
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
      local-docs = "allow";
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
  configuration = home-manager.lib.homeManagerConfiguration {
    pkgs = testPkgs;
    modules = [
      ../../../../modules/programs/ai-agents
      ../../../../modules/programs/claude
      ../../../../modules/programs/codex
      ../../../../modules/programs/pi
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
              ai-agents = {
                enable = true;
                context = "Shared AI tool instructions.";
                permissions = permissionPolicy;
                skills.review-code = ./fixtures/review-code;
                mcp.servers = {
                  local-docs = {
                    command = "test-mcp";
                    args = [ "--stdio" ];
                    env.MODE = "test";
                  };
                  remote-docs = {
                    url = "https://example.invalid/mcp";
                    headers.X-Test = "value";
                  };
                };
              };
              claude-code = {
                enable = true;
                package = claudePackage;
              };
              codex = {
                enable = true;
                package = testPackage "codex";
              };
              pi = {
                enable = true;
                package = testPackage "pi";
              };
              tmux.agentStatusScript = toString (pkgs.writeShellScript "test-agent-status" "exit 0");
            };
          };
        }
      )
    ];
  };
  home = configuration.config.home;
  programs = configuration.config.programs;
  homeFiles = import ../../../lib/home-files.nix {
    inherit lib home;
    pkgs = testPkgs;
  };
  generatedFiles = {
    Claude = homeFiles.generated [
      ".claude/"
      "Library/Application Support/Claude/claude_desktop_config.json"
    ];
    Codex = builtins.sort builtins.lessThan (
      homeFiles.generated [ ".codex/" ]
      ++ lib.optional (lib.hasInfix "/.codex/config.toml" home.activation.codexConfigMerge.data) "~/.codex/config.toml"
    );
    Pi = homeFiles.generated [ ".pi/agent/" ];
  };
  claudeHookNames = [
    "ElicitationResult"
    "Notification"
    "PreToolUse"
    "SessionEnd"
    "SessionStart"
    "Stop"
    "StopFailure"
    "UserPromptSubmit"
  ];
  codexHookKeys = [
    "PermissionRequest"
    "PostToolUse"
    "PreToolUse"
    "SessionStart"
    "Stop"
    "UserPromptSubmit"
    "state"
  ];
  piHookNames = [
    "Notification"
    "PostToolUse"
    "PostToolUseFailure"
    "PreToolUse"
    "SessionEnd"
    "SessionStart"
    "Stop"
    "StopFailure"
    "UserPromptSubmit"
  ];
  claudeMcpServers = {
    local-docs = {
      args = [ "--stdio" ];
      command = "test-mcp";
      env.MODE = "test";
      type = "stdio";
    };
    remote-docs = {
      headers.X-Test = "value";
      type = "http";
      url = "https://example.invalid/mcp";
    };
  };
  codexMcpServers = {
    local-docs = {
      args = [ "--stdio" ];
      command = "test-mcp";
      default_tools_approval_mode = "approve";
      env.MODE = "test";
    };
    remote-docs = {
      http_headers.X-Test = "value";
      url = "https://example.invalid/mcp";
    };
  };
  piMcpServers = {
    local-docs = {
      args = [ "--stdio" ];
      command = "test-mcp";
      env.MODE = "test";
    };
    remote-docs = {
      headers.X-Test = "value";
      url = "https://example.invalid/mcp";
    };
  };
  actual = {
    inherit generatedFiles;
    files = {
      "~/.claude/CLAUDE.md" = homeFiles.materialized ".claude/CLAUDE.md";
      "~/.claude/settings.json" = homeFiles.materialized ".claude/settings.json";
      "~/.claude/skills/claude-code-home-manager/.mcp.json" =
        "${homeFiles.source ".claude/skills/claude-code-home-manager"}/.mcp.json";
      "~/.claude/skills/review-code/SKILL.md" =
        "${homeFiles.source ".claude/skills/review-code"}/SKILL.md";
      "~/Library/Application Support/Claude/claude_desktop_config.json" =
        homeFiles.materialized "Library/Application Support/Claude/claude_desktop_config.json";
      "~/.codex/AGENTS.md" = homeFiles.materialized ".codex/AGENTS.md";
      "~/.codex/config.toml".environment = "SHARED_CODEX_CONFIG";
      "~/.codex/rules/managed.rules" = homeFiles.materialized ".codex/rules/managed.rules";
      "~/.codex/skills/review-code/SKILL.md" = "${homeFiles.source ".codex/skills/review-code"}/SKILL.md";
      "~/.pi/agent/AGENTS.md" = homeFiles.materialized ".pi/agent/AGENTS.md";
      "~/.pi/agent/extensions/hooks/hooks.json" =
        "${homeFiles.source ".pi/agent/extensions/hooks"}/hooks.json";
      "~/.pi/agent/extensions/mcp-adapter/index.ts" =
        "${homeFiles.source ".pi/agent/extensions/mcp-adapter"}/index.ts";
      "~/.pi/agent/mcp.json" = homeFiles.materialized ".pi/agent/mcp.json";
      "~/.pi/agent/settings.json" = homeFiles.materialized ".pi/agent/settings.json";
      "~/.pi/agent/skills/review-code/SKILL.md" =
        "${homeFiles.source ".pi/agent/skills/review-code"}/SKILL.md";
    };
  };
  expected = {
    generatedFiles = {
      Claude = [
        "~/.claude/CLAUDE.md"
        "~/.claude/settings.json"
        "~/.claude/skills/claude-code-home-manager"
        "~/.claude/skills/review-code"
        "~/Library/Application Support/Claude/claude_desktop_config.json"
      ];
      Codex = [
        "~/.codex/AGENTS.md"
        "~/.codex/config.toml"
        "~/.codex/rules/managed.rules"
        "~/.codex/skills/review-code"
      ];
      Pi = [
        "~/.pi/agent/AGENTS.md"
        "~/.pi/agent/extensions/hooks"
        "~/.pi/agent/extensions/mcp-adapter"
        "~/.pi/agent/mcp.json"
        "~/.pi/agent/settings.json"
        "~/.pi/agent/skills/review-code"
      ];
    };
    files = {
      "~/.claude/CLAUDE.md".text = "Shared AI tool instructions.";
      "~/.claude/settings.json".json = {
        contains.permissions = {
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
            "mcp__plugin_hm_*__*"
            "mcp__plugin_hm_local-docs__*"
          ];
          ask = [ ];
          deny = [
            "Edit(docs)"
            "Write"
          ];
        };
        at.hooks.keys = claudeHookNames;
      };
      "~/.claude/skills/claude-code-home-manager/.mcp.json".json.equals = {
        mcpServers = claudeMcpServers;
      };
      "~/.claude/skills/review-code/SKILL.md".sameAs = ./fixtures/review-code/SKILL.md;
      "~/Library/Application Support/Claude/claude_desktop_config.json".json.equals = {
        mcpServers = claudeMcpServers;
      };
      "~/.codex/AGENTS.md".text = "Shared AI tool instructions.";
      "~/.codex/config.toml".toml = {
        contains = {
          default_permissions = "managed";
          permissions.managed = {
            extends = ":workspace";
            filesystem = {
              "/private/tmp" = "write";
              "/private/tmp/**" = "write";
              "/tmp" = "write";
              "/tmp/**" = "write";
              ":workspace_roots"."**/docs" = "read";
            };
            network.enabled = true;
          };
          mcp_servers = codexMcpServers;
        };
        at.hooks.keys = codexHookKeys;
      };
      "~/.codex/rules/managed.rules".text = ''
        prefix_rule(pattern = ["git", "status"], decision = "allow")
      '';
      "~/.codex/skills/review-code/SKILL.md".sameAs = ./fixtures/review-code/SKILL.md;
      "~/.pi/agent/AGENTS.md".text = "Shared AI tool instructions.";
      "~/.pi/agent/extensions/hooks/hooks.json".json = {
        keys = piHookNames;
        contains.Notification = [ { matcher = "permission_prompt"; } ];
      };
      "~/.pi/agent/extensions/mcp-adapter/index.ts".sameAs =
        "${programs.pi.mcp.package}/extension/index.ts";
      "~/.pi/agent/mcp.json".json.equals = {
        settings = { };
        mcpServers = piMcpServers;
      };
      "~/.pi/agent/skills/review-code/SKILL.md".sameAs = ./fixtures/review-code/SKILL.md;
    };
  };
in
{
  inherit actual configuration expected;
}
