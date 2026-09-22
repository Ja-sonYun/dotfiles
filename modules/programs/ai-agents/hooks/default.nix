{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
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
  piCanonicalHooks = hooksFor "pi";
  invalidEventNames = lib.unique (
    lib.concatMap (hooks: lib.subtractLists eventNames (builtins.attrNames hooks)) [
      cfg.hooks
      cfg.hooksByAgent.codex
      cfg.hooksByAgent.claude
      cfg.hooksByAgent.pi
    ]
  );
  codex = import ./adapters/codex.nix {
    canonicalHooks = codexHooks;
    inherit lib pkgs;
  };

  claudeCompatible = import ./adapters/claude-compatible.nix { inherit lib pkgs; };
in
{
  options.programs.ai-agents = {
    hooks = lib.mkOption {
      type = hookSetType;
      default = { };
      description = ''
        Command hooks shared by Codex, Claude Code, and Pi with Claude-compatible
        JSON input and AI_AGENT_CLIENT set. Native tool-failure events are delivered
        to PostToolUse commands with tool_failed = true and the original payload preserved.
        StopFailure is delivered by Claude Code and Pi; SessionInfoChanged by Pi only.
      '';
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
          pi = lib.mkOption {
            type = hookSetType;
            default = { };
          };
        };
      };
      default = { };
      description = "Command hooks applied only to the selected AI agent.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
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

      (lib.mkIf (piCanonicalHooks != { } && config.programs.pi.enable) {
        programs.pi.hooks = claudeCompatible "Pi" piCanonicalHooks;
      })
    ]
  );
}
