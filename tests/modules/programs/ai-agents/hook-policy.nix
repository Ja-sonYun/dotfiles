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
      aiAgentModules.hooks
      ../../../../shell/secrets/modules/home-manager/ai-agents/hooks.nix
    ];
    module.programs.ai-agents.enable = true;
  };
  home = configuration.config.home;
  programs = configuration.config.programs;
  homeFiles = homeFilesFor configuration;
  commandFor = hooks: (builtins.head (builtins.head hooks.SessionStart).hooks).command;
  commandsFor =
    event:
    lib.concatMap (block: map (hook: hook.command) block.hooks) programs.ai-agents.hooks.${event};
  allCommands =
    hooks:
    lib.concatMap (blocks: lib.concatMap (block: block.hooks) blocks) (builtins.attrValues hooks);
  notificationBlocks = programs.ai-agents.hooks.Notification;
  sharedCommand = commandFor programs.ai-agents.hooks;
  codexCommand = commandFor programs.codex.settings.hooks;
  claudeCommand = commandFor programs.claude-code.settings.hooks;
  piCommand = commandFor programs.pi.hooks;
  actual = {
    generatedFiles = {
      Claude = homeFiles.generated [ ".claude/settings.json" ];
      Codex = lib.optional (lib.hasInfix "/.codex/config.toml" home.activation.codexConfigMerge.data) "~/.codex/config.toml";
      Pi = homeFiles.generated [ ".pi/agent/extensions/hooks" ];
    };
    files = {
      "~/.claude/settings.json" = homeFiles.materialized ".claude/settings.json";
      "~/.codex/config.toml" = managedFragment configuration;
      "~/.pi/agent/extensions/hooks/hooks.json" =
        "${homeFiles.source ".pi/agent/extensions/hooks"}/hooks.json";
    };
  };
  expected = {
    generatedFiles = {
      Claude = [ "~/.claude/settings.json" ];
      Codex = [ "~/.codex/config.toml" ];
      Pi = [ "~/.pi/agent/extensions/hooks" ];
    };
    files = {
      "~/.claude/settings.json".json = {
        at.hooks = {
          keys = [
            "Notification"
            "PostToolUse"
            "PreToolUse"
            "SessionEnd"
            "SessionStart"
            "Stop"
            "UserPromptSubmit"
          ];
        };
      };
      "~/.codex/config.toml".toml.at.hooks.keys = [
        "PermissionRequest"
        "PostToolUse"
        "PreToolUse"
        "SessionEnd"
        "SessionStart"
        "Stop"
        "UserPromptSubmit"
      ];
      "~/.pi/agent/extensions/hooks/hooks.json".json = {
        keys = [
          "Notification"
          "PostToolUse"
          "PreToolUse"
          "SessionEnd"
          "SessionStart"
          "Stop"
          "UserPromptSubmit"
        ];
      };
    };
  };
in
assert lib.hasInfix "/status.py" sharedCommand;
assert builtins.length (commandsFor "SessionStart") == 1;
assert builtins.length (commandsFor "PreToolUse") == 1;
assert builtins.length (commandsFor "Notification") == 4;
assert builtins.length (commandsFor "Stop") == 2;
assert
  map (block: block.matcher) notificationBlocks == [
    "permission_prompt"
    "elicitation_dialog|idle_prompt"
  ];
assert
  map (block: builtins.length block.hooks) notificationBlocks == [
    2
    2
  ];
assert lib.count (lib.hasInfix "/status.py") (commandsFor "Notification") == 2;
assert lib.count (lib.hasInfix "/notification.py") (commandsFor "Notification") == 2;
assert lib.hasInfix "Codex" codexCommand;
assert lib.hasInfix "codex_adapter.py" codexCommand;
assert lib.all (hook: lib.hasInfix "codex_adapter.py" hook.command) (
  allCommands programs.codex.settings.hooks
);
assert builtins.hasAttr "PermissionRequest" programs.codex.settings.hooks;
assert builtins.length programs.codex.settings.hooks.PreToolUse == 2;
assert
  (builtins.elemAt programs.codex.settings.hooks.PreToolUse 1).matcher
  == "request_user_input|confirm_|_open_codex_api_key_setup";
assert lib.hasInfix "permission_prompt" (commandFor {
  SessionStart = programs.codex.settings.hooks.PermissionRequest;
});
assert lib.hasInfix "elicitation_dialog" (commandFor {
  SessionStart = [ (builtins.elemAt programs.codex.settings.hooks.PreToolUse 1) ];
});
assert lib.hasInfix "Claude" claudeCommand;
assert !lib.hasInfix "codex_adapter.py" claudeCommand;
assert lib.all (hook: lib.hasInfix "AI_AGENT_CLIENT=Claude" hook.command) (
  allCommands programs.claude-code.settings.hooks
);
assert lib.hasInfix "Pi" piCommand;
assert !lib.hasInfix "codex_adapter.py" piCommand;
assert lib.all (hook: lib.hasInfix "AI_AGENT_CLIENT=Pi" hook.command) (
  allCommands programs.pi.hooks
);
{
  name = "AI agent hook policy";
  inherit actual expected;
}
