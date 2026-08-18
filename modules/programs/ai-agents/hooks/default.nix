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
  invalidEventNames = lib.subtractLists eventNames (builtins.attrNames cfg.hooks);
  codex = import ./codex.nix {
    canonicalHooks = cfg.hooks;
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
  piHooks = normalizeHookSet "Pi" cfg.hooks;
in
{
  options.programs.ai-agents.hooks = lib.mkOption {
    type = lib.types.attrsOf (lib.types.nonEmptyListOf hookTypes.hookBlock);
    default = { };
    description = "Command hooks shared by Codex, Claude Code, and Pi with Claude-compatible JSON input and AI_AGENT_CLIENT set.";
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

      (lib.mkIf (cfg.hooks != { } && config.programs.codex.enable) {
        programs.codex.settings.hooks = codex.hooks;
      })

      (lib.mkIf (cfg.hooks != { } && config.programs.claude-code.enable) {
        programs.claude-code.settings.hooks = normalizeHookSet "Claude" cfg.hooks;
      })

      (lib.mkIf (cfg.hooks != { } && config.programs.pi.enable) {
        programs.pi.hooks = piHooks;
      })
    ]
  );
}
