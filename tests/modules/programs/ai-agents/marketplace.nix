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
  marketplaceHelpers = import ../../../../modules/programs/ai-agents/marketplace/lib.nix {
    inherit lib;
  };
  marketplaceHooksForPlugin = import ../../../../modules/programs/ai-agents/marketplace/hooks.nix {
    helpers = marketplaceHelpers;
    inherit lib;
  };
  strictSkillsMarketplace = ./fixtures/marketplaces/strict-skills;
  validMarketplace = ./fixtures/marketplaces/valid;
  adapterPath = ../../../../modules/programs/ai-agents/hooks/codex_adapter.py;
  featureModules = [
    aiAgentModules.core
    aiAgentModules.hooks
    aiAgentModules.marketplace
    aiAgentModules.mcp
  ];
  configuration = mkConfiguration {
    inherit featureModules;
    module.programs.ai-agents = {
      enable = true;
      hooks.PreToolUse = [
        {
          hooks = [
            {
              command = "manual-hook";
              type = "command";
            }
          ];
        }
      ];
      marketplaces.test = validMarketplace;
      mcp.servers = {
        entry-docs.command = "test-entry-mcp";
        file-docs.command = "test-file-mcp";
        file-entry-docs.command = "test-file-entry-mcp";
        local-docs.command = "test-local-mcp";
        strict-docs.command = "test-strict-mcp";
      };
    };
  };
  programs = configuration.config.programs;
  home = configuration.config.home;
  homeFiles = homeFilesFor configuration;
  inlinePluginRoot = "${validMarketplace}/plugins/inline-tools";
  inlineHooksForHandler =
    handler:
    marketplaceHooksForPlugin "invalid" "inline-tools" inlinePluginRoot false [
      {
        PreToolUse = [
          {
            hooks = [ handler ];
          }
        ];
      }
    ];
  invalidInlineHookFails =
    handler:
    let
      evaluated = builtins.tryEval (builtins.deepSeq (inlineHooksForHandler handler) true);
    in
    !evaluated.success;
  validUnbracedHookCommand =
    (handlerFor (
      builtins.head
        (inlineHooksForHandler {
          command = "$CLAUDE_PLUGIN_ROOT/hook $CLAUDE_PROJECT_DIR";
          type = "command";
        }).PreToolUse
    )).command;
  inlineHookCommand = ''"${inlinePluginRoot}/scripts/pre-tool" "$PWD"'';
  entryHookCommand = ''"${inlinePluginRoot}/scripts/pre-tool" --entry'';
  normalizeCommand =
    client: event: hook:
    let
      clientEnvironment = "export AI_AGENT_CLIENT=${lib.escapeShellArg client}; ";
      timeout = if client == "Codex" && event == "SessionEnd" then 1 else hook.timeout or 600;
      adapterArguments = [
        "${testPkgs.python3}/bin/python"
        "${adapterPath}"
        "--timeout"
        (toString timeout)
        "--"
        hook.command
      ];
    in
    if client == "Codex" then
      "${clientEnvironment}exec ${lib.escapeShellArgs adapterArguments}"
    else
      "${clientEnvironment}${hook.command}";
  normalizeHook =
    client: event: hook:
    hook
    // {
      command = normalizeCommand client event hook;
    }
    // lib.optionalAttrs (client == "Codex") {
      timeout = (if event == "SessionEnd" then 1 else hook.timeout or 600) + 2;
    };
  normalizeBlock =
    client: event: block:
    block
    // {
      hooks = map (normalizeHook client event) block.hooks;
    };
  handlerFor = block: builtins.head block.hooks;
  manualHook = {
    matcher = "";
    hooks = [
      {
        command = "manual-hook";
        type = "command";
      }
    ];
  };
  inlineHook = {
    matcher = "Bash";
    hooks = [
      {
        command = inlineHookCommand;
        timeout = 3;
        type = "command";
      }
    ];
  };
  fileHook = {
    matcher = "";
    hooks = [
      {
        command = "file-hook";
        type = "command";
      }
    ];
  };
  defaultHook = {
    matcher = "";
    hooks = [
      {
        command = "default-hook";
        type = "command";
      }
    ];
  };
  entryHook = {
    matcher = "";
    hooks = [
      {
        command = entryHookCommand;
        type = "command";
      }
    ];
  };
  strictHook = {
    matcher = "";
    hooks = [
      {
        command = "strict-hook";
        type = "command";
      }
    ];
  };
  supplementHook = {
    matcher = "";
    hooks = [
      {
        command = "supplement-hook";
        type = "command";
      }
    ];
  };
  commandsFor = blocks: map (block: (builtins.head block.hooks).command) blocks;
  preToolCommands = {
    Claude = commandsFor programs.claude-code.settings.hooks.PreToolUse;
    Codex = commandsFor programs.codex.settings.hooks.PreToolUse;
    Pi = commandsFor programs.pi.hooks.PreToolUse;
  };
  invalidMarketplaceFails =
    source:
    let
      invalidConfiguration = mkConfiguration {
        inherit featureModules;
        module.programs.ai-agents = {
          enable = true;
          marketplaces.invalid = source;
        };
      };
      evaluated = builtins.tryEval (
        builtins.deepSeq invalidConfiguration.config.programs.ai-agents.hooks true
      );
    in
    !evaluated.success;
  invalidMarketplaceSkillsFail =
    source:
    let
      invalidConfiguration = mkConfiguration {
        inherit featureModules;
        module.programs.ai-agents = {
          enable = true;
          marketplaces.invalid = source;
        };
      };
      evaluated = builtins.tryEval (
        builtins.deepSeq (builtins.attrNames invalidConfiguration.config.programs.ai-agents.skills) true
      );
    in
    !evaluated.success;
  strictSkillsConfiguration = mkConfiguration {
    inherit featureModules;
    module.programs.ai-agents = {
      enable = true;
      marketplaces.strictSkills = strictSkillsMarketplace;
    };
  };
  strictSkillNames = builtins.attrNames strictSkillsConfiguration.config.programs.ai-agents.skills;
  missingMcpConfiguration = mkConfiguration {
    inherit featureModules;
    module.programs.ai-agents = {
      enable = true;
      marketplaces.test = validMarketplace;
    };
  };
  missingMcpEvaluation = builtins.tryEval (
    builtins.deepSeq missingMcpConfiguration.config.assertions true
  );
  packageMarketplace = testPkgs.runCommandLocal "test-marketplace-package" { } ''
    cp -R ${validMarketplace} "$out"
  '';
  packageConfiguration = mkConfiguration {
    inherit featureModules;
    module.programs.ai-agents = {
      enable = true;
      marketplaces.package = packageMarketplace;
      mcp.servers = {
        entry-docs.command = "test-entry-mcp";
        file-docs.command = "test-file-mcp";
        file-entry-docs.command = "test-file-entry-mcp";
        local-docs.command = "test-local-mcp";
        strict-docs.command = "test-strict-mcp";
      };
    };
  };
  packageEvaluation = builtins.tryEval (
    builtins.deepSeq (builtins.attrNames packageConfiguration.config.programs.ai-agents.skills) true
  );
  actual = {
    generatedFiles = {
      Claude = homeFiles.generated [
        ".claude/settings.json"
        ".claude/skills/claude-code-home-manager"
        ".claude/skills/inline-tools-check-docs"
        ".claude/skills/inline-tools-review-code"
        ".claude/skills/root-skill-root-helper"
        ".claude/skills/strict-entry-strict-skill"
        "Library/Application Support/Claude/claude_desktop_config.json"
      ];
      Codex = builtins.sort builtins.lessThan (
        homeFiles.generated [
          ".codex/skills/inline-tools-check-docs"
          ".codex/skills/inline-tools-review-code"
          ".codex/skills/root-skill-root-helper"
          ".codex/skills/strict-entry-strict-skill"
        ]
        ++ lib.optional (lib.hasInfix "/.codex/config.toml" home.activation.codexConfigMerge.data) "~/.codex/config.toml"
      );
      Pi = homeFiles.generated [
        ".pi/agent/extensions/hooks"
        ".pi/agent/extensions/mcp-adapter"
        ".pi/agent/mcp.json"
        ".pi/agent/skills/inline-tools-check-docs"
        ".pi/agent/skills/inline-tools-review-code"
        ".pi/agent/skills/root-skill-root-helper"
        ".pi/agent/skills/strict-entry-strict-skill"
      ];
    };
    files = {
      "~/.claude/settings.json" = homeFiles.materialized ".claude/settings.json";
      "~/.claude/skills/inline-tools-check-docs/SKILL.md" =
        "${homeFiles.source ".claude/skills/inline-tools-check-docs"}/SKILL.md";
      "~/.claude/skills/inline-tools-review-code/SKILL.md" =
        "${homeFiles.source ".claude/skills/inline-tools-review-code"}/SKILL.md";
      "~/.claude/skills/root-skill-root-helper/SKILL.md" =
        "${homeFiles.source ".claude/skills/root-skill-root-helper"}/SKILL.md";
      "~/.claude/skills/strict-entry-strict-skill/SKILL.md" =
        "${homeFiles.source ".claude/skills/strict-entry-strict-skill"}/SKILL.md";
      "~/.codex/config.toml" = managedFragment configuration;
      "~/.codex/skills/inline-tools-check-docs/SKILL.md" =
        "${homeFiles.source ".codex/skills/inline-tools-check-docs"}/SKILL.md";
      "~/.codex/skills/inline-tools-review-code/SKILL.md" =
        "${homeFiles.source ".codex/skills/inline-tools-review-code"}/SKILL.md";
      "~/.codex/skills/root-skill-root-helper/SKILL.md" =
        "${homeFiles.source ".codex/skills/root-skill-root-helper"}/SKILL.md";
      "~/.codex/skills/strict-entry-strict-skill/SKILL.md" =
        "${homeFiles.source ".codex/skills/strict-entry-strict-skill"}/SKILL.md";
      "~/.pi/agent/extensions/hooks/hooks.json" =
        "${homeFiles.source ".pi/agent/extensions/hooks"}/hooks.json";
      "~/.pi/agent/skills/inline-tools-check-docs/SKILL.md" =
        "${homeFiles.source ".pi/agent/skills/inline-tools-check-docs"}/SKILL.md";
      "~/.pi/agent/skills/inline-tools-review-code/SKILL.md" =
        "${homeFiles.source ".pi/agent/skills/inline-tools-review-code"}/SKILL.md";
      "~/.pi/agent/skills/root-skill-root-helper/SKILL.md" =
        "${homeFiles.source ".pi/agent/skills/root-skill-root-helper"}/SKILL.md";
      "~/.pi/agent/skills/strict-entry-strict-skill/SKILL.md" =
        "${homeFiles.source ".pi/agent/skills/strict-entry-strict-skill"}/SKILL.md";
    };
  };
  expectedSkill = ''
    ---
    name: inline-tools-review-code
    description: Review code from a Marketplace plugin.
    ---

    Review the requested code changes.
  '';
  expectedCustomSkill = ''
    ---
    name: inline-tools-check-docs
    description: Check documentation from a custom Marketplace skill path.
    ---

    Check the requested documentation.
  '';
  expectedRootSkill = ''
    ---
    name: root-skill-root-helper
    description: Run a Marketplace skill stored at the plugin root.
    ---

    Run the root helper.
  '';
  expectedStrictSkill = ''
    ---
    name: strict-entry-strict-skill
    description: Load a default skill with strict mode disabled.
    ---

    Run the strict entry skill.
  '';
  expected = {
    generatedFiles = {
      Claude = [
        "~/.claude/settings.json"
        "~/.claude/skills/claude-code-home-manager"
        "~/.claude/skills/inline-tools-check-docs"
        "~/.claude/skills/inline-tools-review-code"
        "~/.claude/skills/root-skill-root-helper"
        "~/.claude/skills/strict-entry-strict-skill"
        "~/Library/Application Support/Claude/claude_desktop_config.json"
      ];
      Codex = [
        "~/.codex/config.toml"
        "~/.codex/skills/inline-tools-check-docs"
        "~/.codex/skills/inline-tools-review-code"
        "~/.codex/skills/root-skill-root-helper"
        "~/.codex/skills/strict-entry-strict-skill"
      ];
      Pi = [
        "~/.pi/agent/extensions/hooks"
        "~/.pi/agent/extensions/mcp-adapter"
        "~/.pi/agent/mcp.json"
        "~/.pi/agent/skills/inline-tools-check-docs"
        "~/.pi/agent/skills/inline-tools-review-code"
        "~/.pi/agent/skills/root-skill-root-helper"
        "~/.pi/agent/skills/strict-entry-strict-skill"
      ];
    };
    files = {
      "~/.claude/settings.json".json.at.hooks = {
        at = {
          PostCompact.contains = [ (normalizeBlock "Claude" "PostCompact" entryHook) ];
          PostToolUse.contains = [ (normalizeBlock "Claude" "PostToolUse" fileHook) ];
          PreToolUse.contains = [
            (normalizeBlock "Claude" "PreToolUse" manualHook)
            (normalizeBlock "Claude" "PreToolUse" inlineHook)
          ];
          SessionEnd.contains = [ (normalizeBlock "Claude" "SessionEnd" defaultHook) ];
          SessionStart.contains = [ (normalizeBlock "Claude" "SessionStart" strictHook) ];
          UserPromptSubmit.contains = [ (normalizeBlock "Claude" "UserPromptSubmit" supplementHook) ];
        };
      };
      "~/.claude/skills/inline-tools-check-docs/SKILL.md".text = expectedCustomSkill;
      "~/.claude/skills/inline-tools-review-code/SKILL.md".text = expectedSkill;
      "~/.claude/skills/root-skill-root-helper/SKILL.md".text = expectedRootSkill;
      "~/.claude/skills/strict-entry-strict-skill/SKILL.md".text = expectedStrictSkill;
      "~/.codex/config.toml".toml.at.hooks = {
        at = {
          PostCompact.contains = [ (normalizeBlock "Codex" "PostCompact" entryHook) ];
          PostToolUse.contains = [ (normalizeBlock "Codex" "PostToolUse" fileHook) ];
          PreToolUse.contains = [
            (normalizeBlock "Codex" "PreToolUse" manualHook)
            (normalizeBlock "Codex" "PreToolUse" inlineHook)
          ];
          SessionEnd.contains = [ (normalizeBlock "Codex" "SessionEnd" defaultHook) ];
          SessionStart.contains = [ (normalizeBlock "Codex" "SessionStart" strictHook) ];
          UserPromptSubmit.contains = [ (normalizeBlock "Codex" "UserPromptSubmit" supplementHook) ];
        };
      };
      "~/.codex/skills/inline-tools-check-docs/SKILL.md".text = expectedCustomSkill;
      "~/.codex/skills/inline-tools-review-code/SKILL.md".text = expectedSkill;
      "~/.codex/skills/root-skill-root-helper/SKILL.md".text = expectedRootSkill;
      "~/.codex/skills/strict-entry-strict-skill/SKILL.md".text = expectedStrictSkill;
      "~/.pi/agent/extensions/hooks/hooks.json".json = {
        at = {
          PostCompact.contains = [ (normalizeBlock "Pi" "PostCompact" entryHook) ];
          PostToolUse.contains = [ (normalizeBlock "Pi" "PostToolUse" fileHook) ];
          PreToolUse.contains = [
            (normalizeBlock "Pi" "PreToolUse" manualHook)
            (normalizeBlock "Pi" "PreToolUse" inlineHook)
          ];
          SessionEnd.contains = [ (normalizeBlock "Pi" "SessionEnd" defaultHook) ];
          SessionStart.contains = [ (normalizeBlock "Pi" "SessionStart" strictHook) ];
          UserPromptSubmit.contains = [ (normalizeBlock "Pi" "UserPromptSubmit" supplementHook) ];
        };
      };
      "~/.pi/agent/skills/inline-tools-check-docs/SKILL.md".text = expectedCustomSkill;
      "~/.pi/agent/skills/inline-tools-review-code/SKILL.md".text = expectedSkill;
      "~/.pi/agent/skills/root-skill-root-helper/SKILL.md".text = expectedRootSkill;
      "~/.pi/agent/skills/strict-entry-strict-skill/SKILL.md".text = expectedStrictSkill;
    };
  };
in
assert
  preToolCommands.Claude == [
    (normalizeCommand "Claude" "PreToolUse" (handlerFor manualHook))
    (normalizeCommand "Claude" "PreToolUse" (handlerFor inlineHook))
  ];
assert
  preToolCommands.Codex == [
    (normalizeCommand "Codex" "PreToolUse" (handlerFor manualHook))
    (normalizeCommand "Codex" "PreToolUse" (handlerFor inlineHook))
  ];
assert
  preToolCommands.Pi == [
    (normalizeCommand "Pi" "PreToolUse" (handlerFor manualHook))
    (normalizeCommand "Pi" "PreToolUse" (handlerFor inlineHook))
  ];
assert invalidMarketplaceFails ./fixtures/marketplaces/unsupported-event;
assert invalidMarketplaceFails ./fixtures/marketplaces/unsupported-handler;
assert invalidMarketplaceFails ./fixtures/marketplaces/unsupported-variable;
assert invalidMarketplaceFails ./fixtures/marketplaces/invalid-hook-path;
assert invalidMarketplaceFails ./fixtures/marketplaces/strict-conflict;
assert invalidMarketplaceFails ./fixtures/marketplaces/external-source;
assert invalidMarketplaceSkillsFail ./fixtures/marketplaces/invalid-skill-name;
assert invalidInlineHookFails {
  command = "hook";
  timeout = 1.5;
  type = "command";
};
assert invalidInlineHookFails {
  command = "$CLAUDE_PLUGIN_ROOT_SUFFIX/hook";
  type = "command";
};
assert invalidInlineHookFails {
  command = "$CLAUDE_PROJECT_DIRECTORY/hook";
  type = "command";
};
assert validUnbracedHookCommand == "${inlinePluginRoot}/hook $PWD";
assert
  strictSkillNames == [
    "strict-skills-selected-double"
    "strict-skills-selected-single"
  ];
assert !missingMcpEvaluation.success;
assert packageEvaluation.success;
{
  name = "AI agents Marketplace";
  inherit actual expected;
}
