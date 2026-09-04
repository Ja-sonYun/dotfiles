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
    ];
    module.programs.ai-agents = {
      enable = true;
      hooks = {
        PostCompact = [
          {
            hooks = [
              {
                command = "test-common-hook";
                type = "command";
              }
            ];
          }
        ];
        SessionEnd = [
          {
            hooks = [
              {
                command = "test-session-end-hook";
                timeout = 5;
                type = "command";
              }
            ];
          }
        ];
      };
    };
  };
  idleNotificationConfiguration = mkConfiguration {
    featureModules = [
      aiAgentModules.core
      aiAgentModules.hooks
    ];
    module.programs.ai-agents = {
      enable = true;
      hooks.Notification = [
        {
          matcher = "idle_prompt";
          hooks = [ { command = "idle-hook"; } ];
        }
      ];
    };
  };
  idleNotificationPrograms = idleNotificationConfiguration.config.programs;
  unsupportedEventFails =
    let
      evaluated = builtins.tryEval (
        builtins.deepSeq
          (mkConfiguration {
            featureModules = [
              aiAgentModules.core
              aiAgentModules.hooks
            ];
            module.programs.ai-agents = {
              enable = true;
              hooks.PostToolUseFailure = [
                {
                  hooks = [ { command = "unsupported-hook"; } ];
                }
              ];
            };
          }).activationPackage
          true
      );
    in
    !evaluated.success;
  home = configuration.config.home;
  homeFiles = homeFilesFor configuration;
  commonCommand = client: command: "export AI_AGENT_CLIENT=${lib.escapeShellArg client}; ${command}";
  codexCommand =
    timeout: command:
    let
      arguments = [
        "${testPkgs.python3}/bin/python"
        "${../../../../modules/programs/ai-agents/hooks/codex_adapter.py}"
        "--timeout"
        (toString timeout)
        "--"
        command
      ];
    in
    "export AI_AGENT_CLIENT=${lib.escapeShellArg "Codex"}; exec ${lib.escapeShellArgs arguments}";
  commonHookExpectation = client: [
    {
      matcher = "";
      hooks = [
        (
          {
            command =
              if client == "Codex" then
                codexCommand 600 "test-common-hook"
              else
                commonCommand client "test-common-hook";
            type = "command";
          }
          // lib.optionalAttrs (client == "Codex") { timeout = 602; }
          # the Pi module keeps its nullable timeout option in hooks.json
          // lib.optionalAttrs (client == "Pi") { timeout = null; }
        )
      ];
    }
  ];
  sessionEndHookExpectation = client: [
    {
      matcher = "";
      hooks = [
        {
          command =
            if client == "Codex" then
              codexCommand 1 "test-session-end-hook"
            else
              commonCommand client "test-session-end-hook";
          timeout = if client == "Codex" then 3 else 5;
          type = "command";
        }
      ];
    }
  ];
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
            "PostCompact"
            "SessionEnd"
          ];
          at = {
            PostCompact.equals = commonHookExpectation "Claude";
            SessionEnd.equals = sessionEndHookExpectation "Claude";
          };
        };
      };
      "~/.codex/config.toml".toml = {
        at.hooks = {
          keys = [
            "PostCompact"
            "SessionEnd"
          ];
          at = {
            PostCompact.equals = commonHookExpectation "Codex";
            SessionEnd.equals = sessionEndHookExpectation "Codex";
          };
        };
      };
      "~/.pi/agent/extensions/hooks/hooks.json".json = {
        keys = [
          "PostCompact"
          "SessionEnd"
        ];
        at = {
          PostCompact.equals = commonHookExpectation "Pi";
          SessionEnd.equals = sessionEndHookExpectation "Pi";
        };
      };
    };
  };
in
assert unsupportedEventFails;
assert !(builtins.hasAttr "PreToolUse" idleNotificationPrograms.codex.settings.hooks);
assert builtins.hasAttr "Notification" idleNotificationPrograms.claude-code.settings.hooks;
assert builtins.hasAttr "Notification" idleNotificationPrograms.pi.hooks;
{
  name = "AI agents hooks";
  inherit actual expected;
}
