{
  pkgs,
  lib,
  agenix-secrets,
  codexConfigFile,
}:
let
  codexHookDir = "${agenix-secrets}/ai-bundle/hooks";

  hookDefinitions = {
    UserPromptSubmit = {
      eventName = "user_prompt_submit";
      entries = [
        { file = "user-prompt-submit.sh"; }
      ];
    };
    PermissionRequest = {
      eventName = "permission_request";
      entries = [
        {
          command = "PATH=${pkgs.terminal-notifier}/bin:$PATH ${pkgs.python3}/bin/python ${toString ./notify.py} '{\"type\":\"permission-request\",\"thread-id\":\"permission\",\"message\":\"Permission requested\"}'";
          timeout = 30;
        }
      ];
    };
  };

  mkCommandHook = entry: {
    type = "command";
    command =
      if entry ? command then
        entry.command
      else
        "CODEX_HOOK_DIR=${codexHookDir} CODEX_HOOK_PYTHON=${pkgs.python3}/bin/python ${pkgs.bash}/bin/bash ${codexHookDir}/${entry.file}";
  };

  mkHook =
    entry:
    (mkCommandHook entry)
    // lib.optionalAttrs (entry ? timeout) {
      timeout = entry.timeout;
    }
    // lib.optionalAttrs (entry ? async) {
      async = entry.async;
    };

  mkHookWithDefaults =
    hook:
    hook
    // {
      timeout = hook.timeout or 600;
      async = hook.async or false;
    };

  mkTrustedHash =
    eventName: hooks:
    "sha256:${
      builtins.hashString "sha256" (
        builtins.toJSON {
          event_name = eventName;
          hooks = map mkHookWithDefaults hooks;
        }
      )
    }";

  mkStateKey =
    eventName: index:
    "${codexConfigFile}:${eventName}:${toString index}:0";

  mkHookStateFor =
    definition:
    let
      hooks = map mkHook definition.entries;
    in
    builtins.genList (index: {
      name = mkStateKey definition.eventName index;
      value = {
        enabled = true;
        trusted_hash = mkTrustedHash definition.eventName [ (builtins.elemAt hooks index) ];
      };
    }) (builtins.length hooks);

  codexHookState = builtins.listToAttrs (
    lib.flatten (lib.mapAttrsToList (_: mkHookStateFor) hookDefinitions)
  );

  codexHookSettings = lib.mapAttrs (_: definition: [
    {
      hooks = map mkHook definition.entries;
    }
  ]) hookDefinitions;
in
{
  state = codexHookState;
}
// codexHookSettings
