{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
  runner = pkgs.callPackage ./package.nix { };
  eventNames = import ./contract/events.nix;
  hookTypes = import ./contract/types.nix { inherit lib; };
  hookSetType = lib.types.attrsOf (lib.types.nonEmptyListOf hookTypes.hookBlock);
  mergeHookSets = hookSets: lib.zipAttrsWith (_: values: lib.concatLists values) hookSets;
  hooksFor =
    agent:
    lib.mapAttrs
      (
        event: blocks:
        if event == "SessionEnd" then
          map (
            block:
            block
            // {
              hooks = map (
                hook:
                hook
                // {
                  timeout = if hook.timeout == null then 3 else hook.timeout;
                }
              ) block.hooks;
            }
          ) blocks
        else
          blocks
      )
      (mergeHookSets [
        cfg.hooks
        cfg.hooksByAgent.${agent}
      ]);
  codexHooks = hooksFor "codex";
  claudeHooks = hooksFor "claude";
  antigravityHooks = hooksFor "antigravity";
  invalidEventNames = lib.unique (
    lib.concatMap (hooks: lib.subtractLists eventNames (builtins.attrNames hooks)) [
      cfg.hooks
      cfg.hooksByAgent.codex
      cfg.hooksByAgent.claude
      cfg.hooksByAgent.antigravity
    ]
  );
  codex = import ./adapters/codex.nix {
    canonicalHooks = codexHooks;
    inherit lib runner;
  };

  claudeCompatible = import ./adapters/claude-compatible.nix {
    inherit lib runner;
  };
  antigravity = import ./adapters/antigravity.nix {
    canonicalHooks = antigravityHooks;
    inherit lib runner;
  };
in
{
  options.programs.ai-agents = {
    hooks = lib.mkOption {
      type = hookSetType;
      default = { };
      description = "Shared AI agent command hooks.";
    };
    hooksByAgent = lib.mkOption {
      type = lib.types.submodule {
        options = {
          codex = lib.mkOption {
            type = hookSetType;
            default = { };
          };
          claude = lib.mkOption {
            type = hookSetType;
            default = { };
          };
          antigravity = lib.mkOption {
            type = hookSetType;
            default = { };
          };
        };
      };
      default = { };
      description = "Command hooks by AI agent.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion =
              !config.programs.antigravity-cli.enable
              ||
                lib.intersectLists antigravity.unsupportedEvents (builtins.attrNames cfg.hooksByAgent.antigravity)
                == [ ];
            message = "Antigravity has unsupported hook events: ${lib.concatStringsSep ", " antigravity.unsupportedEvents}.";
          }
          {
            assertion = !config.programs.antigravity-cli.enable || antigravity.invalidMatchers == [ ];
            message = "Antigravity only supports matchers for tool hooks.";
          }
          {
            assertion = lib.all (
              hooks:
              lib.all (block: lib.all (hook: hook.timeout == null || hook.timeout <= 3) block.hooks) (
                hooks.SessionEnd or [ ]
              )
            ) ([ cfg.hooks ] ++ builtins.attrValues cfg.hooksByAgent);
            message = "programs.ai-agents SessionEnd hook timeout must not exceed 3 seconds.";
          }
          {
            assertion = invalidEventNames == [ ];
            message = "programs.ai-agents.hooks has unsupported events: ${lib.concatStringsSep ", " invalidEventNames}.";
          }
          {
            assertion = !config.programs.codex.enable || codex.invalidNotificationMatchers == [ ];
            message = "Codex only supports literal Notification matchers: ${lib.concatStringsSep ", " codex.notificationTypes}.";
          }
        ];
      }

      (lib.mkIf (codexHooks != { } && config.programs.codex.enable) {
        programs.codex.settings.hooks = codex.hooks;
      })

      (lib.mkIf (claudeHooks != { } && config.programs.claude-code.enable) {
        programs.claude-code.settings.hooks = claudeCompatible "Claude" claudeHooks;
      })

      (lib.mkIf (antigravityHooks != { } && config.programs.antigravity-cli.enable) {
        programs.antigravity-cli.hooks.ai-agents = antigravity.hooks;
        warnings = lib.optional (antigravity.unsupportedEvents != [ ]) (
          "Antigravity native hooks cannot register these shared events: "
          + lib.concatStringsSep ", " antigravity.unsupportedEvents
          + "."
        );
      })
    ]
  );
}
