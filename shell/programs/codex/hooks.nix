{
  pkgs,
  lib,
  agenix-secrets,
  codexConfigFile,
  aiBundle,
}:
let
  codexHookDir = "${agenix-secrets}/ai-bundle/hooks";
  ponytailHookEnv = "CLAUDE_PLUGIN_ROOT=${aiBundle.ponytailSrc} PLUGIN_DATA=$HOME/.codex/ponytail";

  hookDefinitions = {
    SessionStart = {
      eventName = "session_start";
      entries = [
        {
          command = "${ponytailHookEnv} ${pkgs.nodejs_24}/bin/node ${aiBundle.ponytailSrc}/hooks/ponytail-activate.js";
          timeout = 5;
        }
      ];
    };
    UserPromptSubmit = {
      eventName = "user_prompt_submit";
      entries = [
        { file = "user-prompt-submit.sh"; }
        {
          command = "${ponytailHookEnv} ${pkgs.nodejs_24}/bin/node ${aiBundle.ponytailSrc}/hooks/ponytail-mode-tracker.js";
          timeout = 5;
        }
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
    PostToolUse = {
      eventName = "post_tool_use";
      entries = [
        {
          matcher = "apply_patch";
          command = "${pkgs.python3}/bin/python ${codexHookDir}/comment-review.py";
          timeout = 60;
        }
      ];
    };
  };

  mkCommandHook = entry: {
    type = "command";
    command =
      entry.command
        or "CODEX_HOOK_DIR=${codexHookDir} CODEX_HOOK_PYTHON=${pkgs.python3}/bin/python ${pkgs.bash}/bin/bash ${codexHookDir}/${entry.file}";
  };

  mkHook =
    entry:
    (mkCommandHook entry)
    // lib.optionalAttrs (entry ? timeout) {
      inherit (entry) timeout;
    }
    // lib.optionalAttrs (entry ? async) {
      inherit (entry) async;
    };

  mkHookWithDefaults =
    hook:
    hook
    // {
      timeout = hook.timeout or 600;
      async = hook.async or false;
    };

  mkTrustedHash =
    eventName: matcher: hooks:
    "sha256:${
      builtins.hashString "sha256" (
        builtins.toJSON (
          {
            event_name = eventName;
            hooks = map mkHookWithDefaults hooks;
          }
          // lib.optionalAttrs (matcher != null) { inherit matcher; }
        )
      )
    }";

  mkStateKey = eventName: index: "${codexConfigFile}:${eventName}:${toString index}:0";

  mkHookStateFor =
    definition:
    let
      inherit (definition) entries;
    in
    builtins.genList (
      index:
      let
        entry = builtins.elemAt entries index;
      in
      {
        name = mkStateKey definition.eventName index;
        value = {
          enabled = true;
          trusted_hash = mkTrustedHash definition.eventName (entry.matcher or null) [ (mkHook entry) ];
        };
      }
    ) (builtins.length entries);

  codexHookState = builtins.listToAttrs (
    lib.flatten (lib.mapAttrsToList (_: mkHookStateFor) hookDefinitions)
  );

  codexHookSettings = lib.mapAttrs (
    _: definition:
    map (
      entry:
      {
        hooks = [ (mkHook entry) ];
      }
      // lib.optionalAttrs (entry ? matcher) { inherit (entry) matcher; }
    ) definition.entries
  ) hookDefinitions;
in
{
  state = codexHookState;
}
// codexHookSettings
