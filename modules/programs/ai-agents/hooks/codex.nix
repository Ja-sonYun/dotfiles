{
  canonicalHooks,
  lib,
  pkgs,
}:
let
  notificationTypes = [
    "elicitation_dialog"
    "idle_prompt"
    "permission_prompt"
  ];
  notificationTypesFor =
    matcher:
    let
      normalized = builtins.replaceStrings [ "," " " ] [ "|" "" ] matcher;
    in
    if normalized == "" then
      notificationTypes
    else
      lib.filter (value: value != "") (lib.splitString "|" normalized);
  notificationBlocks = canonicalHooks.Notification or [ ];
  invalidNotificationMatchers = lib.filter (
    block: lib.subtractLists notificationTypes (notificationTypesFor block.matcher) != [ ]
  ) notificationBlocks;
  inputToolMatcher = "request_user_input|confirm_|_open_codex_api_key_setup";

  adapterFor = event: notificationType: {
    inherit event notificationType;
  };
  passthroughAdapter = adapterFor null null;
  normalizeHook =
    adapter: hook:
    let
      timeout = if hook.timeout == null then 600 else hook.timeout;
      adapterArguments = [
        "${pkgs.python3}/bin/python"
        "${./codex_adapter.py}"
        "--timeout"
        (toString timeout)
      ]
      ++ lib.optionals (adapter.event != null) [
        "--event"
        adapter.event
      ]
      ++ lib.optionals (adapter.notificationType != null) [
        "--notification-type"
        adapter.notificationType
      ]
      ++ [
        "--"
        hook.command
      ];
    in
    hook
    // {
      command = "export AI_AGENT_CLIENT=Codex; exec ${lib.escapeShellArgs adapterArguments}";
      timeout = timeout + 2;
    };
  normalizeBlock =
    adapter: block:
    block
    // {
      hooks = map (normalizeHook adapter) block.hooks;
    };
  normalizeHookSet =
    adapter: hooks: lib.mapAttrs (_: blocks: map (normalizeBlock adapter) blocks) hooks;
  selectEvents = events: lib.filterAttrs (event: _: builtins.elem event events) canonicalHooks;
  mergeHookSets = lib.zipAttrsWith (_: values: lib.concatLists values);

  passthroughEvents = [
    "PostCompact"
    "PostToolUse"
    "PreCompact"
    "PreToolUse"
    "SessionEnd"
    "SessionStart"
    "Stop"
    "UserPromptSubmit"
  ];
  notificationHooks = lib.concatMap (
    block:
    let
      types = notificationTypesFor block.matcher;
      permissionHooks = lib.optional (builtins.elem "permission_prompt" types) {
        PermissionRequest = [
          (normalizeBlock (adapterFor "Notification" "permission_prompt") (block // { matcher = ""; }))
        ];
      };
      inputHooks = lib.optional (builtins.elem "elicitation_dialog" types) {
        PreToolUse = [
          (normalizeBlock (adapterFor "Notification" "elicitation_dialog") (
            block // { matcher = inputToolMatcher; }
          ))
        ];
      };
    in
    permissionHooks ++ inputHooks
  ) notificationBlocks;
in
{
  inherit invalidNotificationMatchers notificationTypes;
  hooks = mergeHookSets (
    [
      (normalizeHookSet passthroughAdapter (selectEvents passthroughEvents))
    ]
    ++ notificationHooks
  );
}
