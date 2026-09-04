{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
  eventNames = import ./events.nix;
  hookTypes = import ./types.nix { inherit lib; };
  hookSetType = lib.types.attrsOf (lib.types.nonEmptyListOf hookTypes.hookBlock);
  mergeHookSets = hookSets: lib.zipAttrsWith (_: values: lib.concatLists values) hookSets;
  hooksFor =
    agent:
    mergeHookSets [
      cfg.hooks
      cfg.hooksByAgent.${agent}
    ];
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
  codex = import ./codex.nix {
    canonicalHooks = codexHooks;
    inherit lib pkgs;
  };

  normalizeHook =
    client: hook:
    lib.filterAttrs (_: value: value != null) (
      hook
      // {
        command = "export AI_AGENT_CLIENT=${lib.escapeShellArg client}; ${hook.command}";
      }
    );
  normalizeBlock =
    client: block:
    block
    // {
      hooks = map (normalizeHook client) block.hooks;
    };
  normalizeHookSet =
    client: hooks: lib.mapAttrs (_: blocks: map (normalizeBlock client) blocks) hooks;
  piHooks = normalizeHookSet "Pi" piCanonicalHooks;
in
{
  options.programs.ai-agents = {
    hooks = lib.mkOption {
      type = hookSetType;
      default = { };
      description = "Command hooks shared by Codex, Claude Code, and Pi with Claude-compatible JSON input and AI_AGENT_CLIENT set.";
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
        programs.claude-code.settings.hooks = normalizeHookSet "Claude" claudeHooks;
      })

      (lib.mkIf (piCanonicalHooks != { } && config.programs.pi.enable) {
        programs.pi.hooks = piHooks;
      })
    ]
  );
}
