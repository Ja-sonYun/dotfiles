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
      aiAgentModules.agents
      aiAgentModules.core
      aiAgentModules.mcp
    ];
    module.programs.ai-agents = {
      enable = true;
      context = "Shared AI tool instructions.";
      skills.review-code = ./fixtures/review-code;
      agentsDir = ./fixtures;
      mcp.servers = {
        docs.command = "test-docs-mcp";
        other.command = "test-other-mcp";
      };
    };
  };
  disabledConfiguration = mkConfiguration {
    featureModules = [
      aiAgentModules.agents
      aiAgentModules.core
      aiAgentModules.mcp
    ];
    module.programs.ai-agents = {
      enable = false;
      context = "Disabled AI tool instructions.";
      skills.review-code = ./fixtures/review-code;
      agentsDir = ./fixtures;
    };
  };
  directConfiguration = mkConfiguration {
    featureModules = [
      aiAgentModules.agents
      aiAgentModules.core
      aiAgentModules.mcp
    ];
    module.programs = {
      ai-agents.enable = true;
      codex = {
        context = "Codex-only instructions.";
        agentsDir = ./fixtures;
      };
      pi.context = "Pi-only instructions.";
    };
  };
  programs = configuration.config.programs;
  adaptedAgents = programs.ai-agents.adaptedAgents;
  disabledPrograms = disabledConfiguration.config.programs;
  directPrograms = directConfiguration.config.programs;
  homeFiles = homeFilesFor configuration;
  actual = {
    generatedFiles = {
      Claude = homeFiles.generated [
        ".claude/CLAUDE.md"
        ".claude/agents"
        ".claude/skills/review-code"
      ];
      Codex = builtins.sort builtins.lessThan (
        homeFiles.generated [
          ".codex/AGENTS.md"
          ".codex/skills/review-code"
        ]
        ++ lib.optional (lib.hasInfix "/.codex/config.toml" configuration.config.home.activation.codexConfigMerge.data) "~/.codex/config.toml"
      );
      Pi = homeFiles.generated [
        ".pi/agent/AGENTS.md"
        ".pi/agent/agents"
        ".pi/agent/skills/review-code"
      ];
    };
    files = {
      "~/.claude/CLAUDE.md" = homeFiles.materialized ".claude/CLAUDE.md";
      "~/.claude/agents/test-agent.md" = "${homeFiles.source ".claude/agents"}/test-agent.md";
      "~/.claude/skills/review-code/SKILL.md" =
        "${homeFiles.source ".claude/skills/review-code"}/SKILL.md";
      "~/.codex/AGENTS.md" = homeFiles.materialized ".codex/AGENTS.md";
      "~/.codex/agents/test-agent.toml" = "${adaptedAgents}/codex/test-agent.toml";
      "~/.codex/config.toml" = managedFragment configuration;
      "~/.codex/skills/review-code/SKILL.md" = "${homeFiles.source ".codex/skills/review-code"}/SKILL.md";
      "~/.pi/agent/AGENTS.md" = homeFiles.materialized ".pi/agent/AGENTS.md";
      "~/.pi/agent/agents/test-agent.md" = "${homeFiles.source ".pi/agent/agents"}/test-agent.md";
      "~/.pi/agent/skills/review-code/SKILL.md" =
        "${homeFiles.source ".pi/agent/skills/review-code"}/SKILL.md";
    };
  };
  expected = {
    generatedFiles = {
      Claude = [
        "~/.claude/CLAUDE.md"
        "~/.claude/agents"
        "~/.claude/skills/review-code"
      ];
      Codex = [
        "~/.codex/AGENTS.md"
        "~/.codex/config.toml"
        "~/.codex/skills/review-code"
      ];
      Pi = [
        "~/.pi/agent/AGENTS.md"
        "~/.pi/agent/agents"
        "~/.pi/agent/skills/review-code"
      ];
    };
    files = {
      "~/.claude/CLAUDE.md".text = "Shared AI tool instructions.";
      "~/.claude/agents/test-agent.md".sameAs = ./fixtures/test-agent.md;
      "~/.claude/skills/review-code/SKILL.md".sameAs = ./fixtures/review-code/SKILL.md;
      "~/.codex/AGENTS.md".text = "Shared AI tool instructions.";
      "~/.codex/agents/test-agent.toml".toml.contains = {
        sandbox_mode = "read-only";
        mcp_servers.other.enabled = false;
      };
      "~/.codex/config.toml".toml.at.agents = {
        keys = [ "test-agent" ];
        at.test-agent = {
          keys = [
            "config_file"
            "description"
          ];
          at.description.equals = "Test agent fixture.";
        };
      };
      "~/.codex/skills/review-code/SKILL.md".sameAs = ./fixtures/review-code/SKILL.md;
      "~/.pi/agent/AGENTS.md".text = "Shared AI tool instructions.";
      "~/.pi/agent/agents/test-agent.md".text = ''
        ---
        name: test-agent
        description: Test agent fixture.
        tools:
        - mcp__docs
        ---

        Follow the test agent instructions.
      '';
      "~/.pi/agent/skills/review-code/SKILL.md".sameAs = ./fixtures/review-code/SKILL.md;
    };
  };
in
assert programs.codex.agentsDir == "${adaptedAgents}/codex";
assert programs.claude-code.agentsDir == "${adaptedAgents}/claude";
assert programs.pi.agentsDir == "${adaptedAgents}/pi";
assert disabledPrograms.codex.context == null;
assert disabledPrograms.codex.skills == { };
assert disabledPrograms.codex.agentsDir == null;
assert disabledPrograms.claude-code.context == null;
assert disabledPrograms.claude-code.skills == { };
assert disabledPrograms.claude-code.agentsDir == null;
assert disabledPrograms.pi.context == null;
assert disabledPrograms.pi.skills == { };
assert disabledPrograms.pi.agentsDir == null;
assert directPrograms.codex.context == "Codex-only instructions.";
assert directPrograms.codex.agentsDir == ./fixtures;
assert directPrograms.pi.context == "Pi-only instructions.";
{
  name = "AI agents core";
  inherit actual expected;
}
