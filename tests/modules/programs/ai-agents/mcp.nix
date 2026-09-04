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
  configuration = mkConfiguration {
    featureModules = [
      aiAgentModules.core
      aiAgentModules.mcp
    ];
    module.programs.ai-agents = {
      enable = true;
      mcp.servers = {
        disabled-docs = {
          command = "disabled-mcp";
          disabled = true;
        };
        local-docs = {
          command = "test-mcp";
          args = [ "--stdio" ];
          env.MODE = "test";
        };
        remote-docs = {
          url = "https://example.invalid/mcp";
          headers.X-Test = "value";
        };
        secret-docs = {
          command = "secret-mcp";
          args = [ "--secret" ];
          env = {
            MODE = "secret";
            TOKEN.file = toString ./fixtures/mcp-token;
          };
        };
      };
    };
  };
  invalidServerFails =
    server:
    let
      evaluated = builtins.tryEval (
        builtins.deepSeq
          (mkConfiguration {
            featureModules = [
              aiAgentModules.core
              aiAgentModules.mcp
            ];
            module.programs.ai-agents = {
              enable = true;
              mcp.servers.invalid = server;
            };
          }).activationPackage
          true
      );
    in
    !evaluated.success;
  home = configuration.config.home;
  programs = configuration.config.programs;
  homeFiles = homeFilesFor configuration;
  secretCommand = programs.codex.settings.mcp_servers.secret-docs.command;
  bridgeCommand = programs.claude-code.desktopConfig.mcpServers.remote-docs.command;
  claudeMcpServers = {
    disabled-docs = {
      command = "disabled-mcp";
      type = "stdio";
    };
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
    secret-docs = {
      command = secretCommand;
      env.MODE = "secret";
      type = "stdio";
    };
  };
  claudeDesktopMcpServers = claudeMcpServers // {
    remote-docs = {
      command = bridgeCommand;
      type = "stdio";
    };
  };
  codexMcpServers = {
    disabled-docs = {
      command = "disabled-mcp";
      enabled = false;
    };
    local-docs = {
      args = [ "--stdio" ];
      command = "test-mcp";
      env.MODE = "test";
    };
    remote-docs = {
      http_headers.X-Test = "value";
      url = "https://example.invalid/mcp";
    };
    secret-docs = {
      command = secretCommand;
      env.MODE = "secret";
    };
  };
  piMcpServers = {
    disabled-docs = {
      command = "disabled-mcp";
      disabled = true;
    };
    local-docs = {
      args = [ "--stdio" ];
      command = "test-mcp";
      env.MODE = "test";
    };
    remote-docs = {
      headers.X-Test = "value";
      url = "https://example.invalid/mcp";
    };
    secret-docs = {
      command = secretCommand;
      env.MODE = "secret";
    };
  };
  actual = {
    generatedFiles = {
      Claude = homeFiles.generated [
        ".claude/settings.json"
        ".claude/skills/claude-code-home-manager"
        "Library/Application Support/Claude/claude_desktop_config.json"
      ];
      Codex = lib.optional (lib.hasInfix "/.codex/config.toml" home.activation.codexConfigMerge.data) "~/.codex/config.toml";
      Pi = homeFiles.generated [
        ".pi/agent/extensions/mcp-adapter"
        ".pi/agent/mcp.json"
      ];
    };
    files = {
      "~/.claude/settings.json" = homeFiles.materialized ".claude/settings.json";
      "~/.claude/skills/claude-code-home-manager/.mcp.json" =
        "${homeFiles.source ".claude/skills/claude-code-home-manager"}/.mcp.json";
      "~/Library/Application Support/Claude/claude_desktop_config.json" =
        homeFiles.materialized "Library/Application Support/Claude/claude_desktop_config.json";
      "mcp remote bridge" = bridgeCommand;
      "~/.codex/config.toml" = managedFragment configuration;
      "~/.pi/agent/extensions/mcp-adapter/index.ts" =
        "${homeFiles.source ".pi/agent/extensions/mcp-adapter"}/index.ts";
      "~/.pi/agent/mcp.json" = homeFiles.materialized ".pi/agent/mcp.json";
    };
  };
  expected = {
    generatedFiles = {
      Claude = [
        "~/.claude/settings.json"
        "~/.claude/skills/claude-code-home-manager"
        "~/Library/Application Support/Claude/claude_desktop_config.json"
      ];
      Codex = [ "~/.codex/config.toml" ];
      Pi = [
        "~/.pi/agent/extensions/mcp-adapter"
        "~/.pi/agent/mcp.json"
      ];
    };
    files = {
      "~/.claude/settings.json".json.at.disabledMcpjsonServers.equals = [ "disabled-docs" ];
      "~/.claude/skills/claude-code-home-manager/.mcp.json".json.equals = {
        mcpServers = claudeMcpServers;
      };
      "~/Library/Application Support/Claude/claude_desktop_config.json".json.equals = {
        mcpServers = claudeDesktopMcpServers;
      };
      "mcp remote bridge".text = ''
        #!${testPkgs.runtimeShell}
        exec ${
          lib.escapeShellArgs [
            "${testPkgs.mcp-remote}/bin/mcp-remote"
            "https://example.invalid/mcp"
            "--header"
            "X-Test: value"
          ]
        }
      ''
      # writeShellScript appends a trailing newline of its own
      + "\n";
      "~/.codex/config.toml".toml.equals.mcp_servers = codexMcpServers;
      "~/.pi/agent/extensions/mcp-adapter/index.ts".sameAs =
        "${programs.pi.mcp.package}/extension/index.ts";
      "~/.pi/agent/mcp.json".json.equals = {
        settings = { };
        mcpServers = piMcpServers;
      };
    };
  };
in
assert lib.hasInfix "mcp-secret-docs-wrapper" secretCommand;
assert programs.claude-code.mcpServers.secret-docs.command == secretCommand;
assert programs.pi.mcp.servers.secret-docs.command == secretCommand;
assert !lib.hasInfix "test-token" (builtins.toJSON claudeMcpServers);
assert !lib.hasInfix "test-token" (builtins.toJSON codexMcpServers);
assert !lib.hasInfix "test-token" (builtins.toJSON piMcpServers);
assert invalidServerFails { };
assert invalidServerFails {
  command = "invalid-mcp";
  url = "https://example.invalid/mcp";
};
assert invalidServerFails {
  args = [ "--invalid" ];
  env.MODE = "invalid";
  url = "https://example.invalid/mcp";
};
assert invalidServerFails {
  command = "invalid-mcp";
  headers.X-Test = "invalid";
};
assert invalidServerFails {
  command = "invalid-mcp";
  disabled = true;
  enabled = true;
};
assert invalidServerFails {
  command = "invalid-mcp";
  disabled = "false";
};
{
  name = "AI agents MCP";
  inherit actual expected;
}
