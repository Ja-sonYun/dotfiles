{ lib, pkgs }:
let
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
  normalizeFailureHook =
    client: hook:
    let
      arguments = [
        "${pkgs.python3}/bin/python"
        "${./post_tool_adapter.py}"
      ]
      ++ lib.optionals (hook.timeout != null) [
        "--timeout"
        (toString hook.timeout)
      ]
      ++ [
        "--"
        hook.command
      ];
    in
    normalizeHook client (
      hook
      // {
        command = "exec ${lib.escapeShellArgs arguments}";
        timeout = if hook.timeout == null then null else hook.timeout + 4;
      }
    );
in
client: hooks:
lib.mapAttrs (_: blocks: map (normalizeBlock client) blocks) (
  lib.filterAttrs (event: _: client == "Pi" || event != "SessionInfoChanged") hooks
)
// lib.optionalAttrs (hooks ? PostToolUse) {
  PostToolUseFailure = map (
    block:
    block
    // {
      hooks = map (normalizeFailureHook client) block.hooks;
    }
  ) hooks.PostToolUse;
}
