{
  aiAgentModules,
  homeFilesFor,
  mkConfiguration,
  ...
}:
let
  configuration = mkConfiguration {
    featureModules = [ aiAgentModules.core ];
    module.programs.ai-agents = {
      enable = true;
      context = "Shared AI tool instructions.";
      skills.review-code = ./fixtures/review-code;
      agentsDir = ./fixtures;
    };
  };
  disabledConfiguration = mkConfiguration {
    featureModules = [ aiAgentModules.core ];
    module.programs.ai-agents = {
      enable = false;
      context = "Disabled AI tool instructions.";
      skills.review-code = ./fixtures/review-code;
      agentsDir = ./fixtures;
    };
  };
  directConfiguration = mkConfiguration {
    featureModules = [ aiAgentModules.core ];
    module.programs = {
      ai-agents.enable = true;
      codex = {
        context = "Codex-only instructions.";
        claudeAgentsDir = ./fixtures;
      };
      pi.context = "Pi-only instructions.";
    };
  };
  programs = configuration.config.programs;
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
      Codex = homeFiles.generated [
        ".codex/AGENTS.md"
        ".codex/agents/test-agent.toml"
        ".codex/skills/review-code"
      ];
      Pi = homeFiles.generated [
        ".pi/agent/AGENTS.md"
        ".pi/agent/skills/review-code"
      ];
    };
    files = {
      "~/.claude/CLAUDE.md" = homeFiles.materialized ".claude/CLAUDE.md";
      "~/.claude/agents/test-agent.md" = "${homeFiles.source ".claude/agents"}/test-agent.md";
      "~/.claude/skills/review-code/SKILL.md" =
        "${homeFiles.source ".claude/skills/review-code"}/SKILL.md";
      "~/.codex/AGENTS.md" = homeFiles.materialized ".codex/AGENTS.md";
      "~/.codex/agents/test-agent.toml" = homeFiles.materialized ".codex/agents/test-agent.toml";
      "~/.codex/skills/review-code/SKILL.md" = "${homeFiles.source ".codex/skills/review-code"}/SKILL.md";
      "~/.pi/agent/AGENTS.md" = homeFiles.materialized ".pi/agent/AGENTS.md";
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
        "~/.codex/agents/test-agent.toml"
        "~/.codex/skills/review-code"
      ];
      Pi = [
        "~/.pi/agent/AGENTS.md"
        "~/.pi/agent/skills/review-code"
      ];
    };
    files = {
      "~/.claude/CLAUDE.md".text = "Shared AI tool instructions.";
      "~/.claude/agents/test-agent.md".sameAs = ./fixtures/test-agent.md;
      "~/.claude/skills/review-code/SKILL.md".sameAs = ./fixtures/review-code/SKILL.md;
      "~/.codex/AGENTS.md".text = "Shared AI tool instructions.";
      "~/.codex/agents/test-agent.toml".toml.contains = {
        name = "test-agent";
        description = "Test agent fixture.";
        sandbox_mode = "read-only";
      };
      "~/.codex/skills/review-code/SKILL.md".sameAs = ./fixtures/review-code/SKILL.md;
      "~/.pi/agent/AGENTS.md".text = "Shared AI tool instructions.";
      "~/.pi/agent/skills/review-code/SKILL.md".sameAs = ./fixtures/review-code/SKILL.md;
    };
  };
in
assert programs.codex.claudeAgentsDir == ./fixtures;
assert programs.claude-code.agentsDir == ./fixtures;
assert disabledPrograms.codex.context == null;
assert disabledPrograms.codex.skills == { };
assert disabledPrograms.codex.claudeAgentsDir == null;
assert disabledPrograms.claude-code.context == null;
assert disabledPrograms.claude-code.skills == { };
assert disabledPrograms.claude-code.agentsDir == null;
assert disabledPrograms.pi.context == null;
assert disabledPrograms.pi.skills == { };
assert directPrograms.codex.context == "Codex-only instructions.";
assert directPrograms.codex.claudeAgentsDir == ./fixtures;
assert directPrograms.pi.context == "Pi-only instructions.";
{
  name = "AI agents core";
  inherit actual expected;
}
