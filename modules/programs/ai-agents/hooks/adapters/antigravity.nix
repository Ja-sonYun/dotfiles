{
  canonicalHooks,
  lib,
  runner,
}:
let
  supportedEvents = [
    "SessionStart"
    "PreToolUse"
    "PostToolUse"
    "Stop"
    "StopFailure"
  ];
  toolEvents = [
    "PreToolUse"
    "PostToolUse"
  ];
  selectedHooks = lib.filterAttrs (event: _: builtins.elem event supportedEvents) canonicalHooks;
  normalizeHook = event: hook: {
    type = "command";
    command = "export AI_AGENT_CLIENT=Antigravity; exec ${
      lib.escapeShellArgs [
        (lib.getExe runner)
        "antigravity"
        "--timeout"
        (toString (if hook.timeout == null then 600 else hook.timeout))
        "--event"
        event
        "--"
        hook.command
      ]
    }";
    timeout = (if hook.timeout == null then 600 else hook.timeout) + 4;
  };
in
{
  unsupportedEvents = lib.subtractLists supportedEvents (builtins.attrNames canonicalHooks);
  invalidMatchers = lib.concatLists (
    lib.mapAttrsToList (
      event: blocks: lib.filter (block: !builtins.elem event toolEvents && block.matcher != "") blocks
    ) selectedHooks
  );

  # Only tool events use matcher blocks in the native hooks file.
  hooks = lib.zipAttrsWith (_: values: lib.concatLists values) (
    lib.mapAttrsToList (event: blocks: {
      ${if event == "StopFailure" then "Stop" else event} =
        if builtins.elem event toolEvents then
          map (block: {
            matcher = if block.matcher == "" then ".*" else block.matcher;
            hooks = map (normalizeHook event) block.hooks;
          }) blocks
        else
          lib.concatMap (block: map (normalizeHook event) block.hooks) blocks;
    }) selectedHooks
  );
}
