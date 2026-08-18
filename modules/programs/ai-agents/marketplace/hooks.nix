{
  helpers,
  lib,
}:
let
  eventNames = import ../hooks/common-events.nix;
  inherit (helpers) fail pluginRelativePath readJson;

  normalizeHookHandler =
    marketplace: pluginName: pluginRoot: eventName: blockIndex: hookIndex: handler:
    let
      location = "plugin `${pluginName}` hook `${eventName}` block ${toString blockIndex} handler ${toString hookIndex}";
      unexpectedFields = lib.subtractLists [
        "command"
        "timeout"
        "type"
      ] (builtins.attrNames handler);
      timeoutValid = !(handler ? timeout) || (builtins.isInt handler.timeout && handler.timeout > 0);
      hasIdentifierSuffix =
        variable:
        lib.any (suffix: builtins.match "[A-Za-z0-9_].*" suffix != null) (
          builtins.tail (lib.splitString variable handler.command)
        );
      hasPrefixedSupportedVariable =
        hasIdentifierSuffix "$CLAUDE_PLUGIN_ROOT" || hasIdentifierSuffix "$CLAUDE_PROJECT_DIR";
      command =
        builtins.replaceStrings
          [
            "\${CLAUDE_PLUGIN_ROOT}"
            "$CLAUDE_PLUGIN_ROOT"
            "\${CLAUDE_PROJECT_DIR}"
            "$CLAUDE_PROJECT_DIR"
          ]
          [
            pluginRoot
            pluginRoot
            "\${PWD}"
            "$PWD"
          ]
          handler.command;
      hasClaudeVariable =
        hasPrefixedSupportedVariable
        || lib.hasInfix "$CLAUDE_" command
        || lib.hasInfix "\${CLAUDE_" command;
    in
    if !builtins.isAttrs handler then
      fail marketplace "${location} must be a JSON object."
    else if unexpectedFields != [ ] then
      fail marketplace "${location} has unsupported fields: ${lib.concatStringsSep ", " unexpectedFields}."
    else if !(handler ? type) || !builtins.isString handler.type || handler.type != "command" then
      fail marketplace "${location} must have `type` set to `command`."
    else if !(handler ? command) || !builtins.isString handler.command || handler.command == "" then
      fail marketplace "${location} must have a non-empty string `command`."
    else if !timeoutValid then
      fail marketplace "${location} `timeout` must be a positive integer."
    else if hasClaudeVariable then
      fail marketplace "${location} contains an unsupported `CLAUDE_*` variable."
    else
      {
        inherit command;
        type = "command";
      }
      // lib.optionalAttrs (handler ? timeout) { inherit (handler) timeout; };

  normalizeHookBlock =
    marketplace: pluginName: pluginRoot: eventName: blockIndex: block:
    let
      location = "plugin `${pluginName}` hook `${eventName}` block ${toString blockIndex}";
      unexpectedFields = lib.subtractLists [
        "hooks"
        "matcher"
      ] (builtins.attrNames block);
      matcher = block.matcher or "";
    in
    if !builtins.isAttrs block then
      fail marketplace "${location} must be a JSON object."
    else if unexpectedFields != [ ] then
      fail marketplace "${location} has unsupported fields: ${lib.concatStringsSep ", " unexpectedFields}."
    else if !builtins.isString matcher then
      fail marketplace "${location} `matcher` must be a string."
    else if !(block ? hooks) || !builtins.isList block.hooks || block.hooks == [ ] then
      fail marketplace "${location} must have a non-empty `hooks` list."
    else
      {
        inherit matcher;
        hooks = lib.imap0 (
          hookIndex: normalizeHookHandler marketplace pluginName pluginRoot eventName blockIndex hookIndex
        ) block.hooks;
      };

  normalizeHookEvents =
    marketplace: pluginName: pluginRoot: hooks:
    let
      invalidEventNames = lib.subtractLists eventNames (builtins.attrNames hooks);
    in
    if !builtins.isAttrs hooks then
      fail marketplace "plugin `${pluginName}` hooks must be a JSON object."
    else if invalidEventNames != [ ] then
      fail marketplace "plugin `${pluginName}` has unsupported hook events: ${lib.concatStringsSep ", " invalidEventNames}."
    else
      lib.mapAttrs (
        eventName: blocks:
        if !builtins.isList blocks || blocks == [ ] then
          fail marketplace "plugin `${pluginName}` hook `${eventName}` must be a non-empty list."
        else
          lib.imap0 (normalizeHookBlock marketplace pluginName pluginRoot eventName) blocks
      ) hooks;

  readHookFile =
    marketplace: pluginName: pluginRoot: path:
    let
      value = readJson marketplace "plugin `${pluginName}` hook configuration" path;
      unexpectedFields = lib.subtractLists [
        "description"
        "hooks"
      ] (builtins.attrNames value);
    in
    if !builtins.isAttrs value then
      fail marketplace "plugin `${pluginName}` hook configuration must be a JSON object."
    else if unexpectedFields != [ ] then
      fail marketplace "plugin `${pluginName}` hook configuration has unsupported fields: ${lib.concatStringsSep ", " unexpectedFields}."
    else if value ? description && !builtins.isString value.description then
      fail marketplace "plugin `${pluginName}` hook configuration `description` must be a string."
    else if !(value ? hooks) || !builtins.isAttrs value.hooks then
      fail marketplace "plugin `${pluginName}` hook configuration must contain a `hooks` object."
    else
      normalizeHookEvents marketplace pluginName pluginRoot value.hooks;
in
marketplace: pluginName: pluginRoot: useDefault: declarations:
let
  defaultHooksPath = "${pluginRoot}/hooks/hooks.json";
  hooksFor =
    declaration:
    if builtins.isAttrs declaration then
      normalizeHookEvents marketplace pluginName pluginRoot declaration
    else if builtins.isString declaration then
      readHookFile marketplace pluginName pluginRoot (
        pluginRelativePath marketplace pluginName "hook configuration path" pluginRoot false declaration
      )
    else
      fail marketplace "plugin `${pluginName}` `hooks` must be an object or relative path.";
  hookSets =
    lib.optional (useDefault && builtins.pathExists defaultHooksPath) (
      readHookFile marketplace pluginName pluginRoot defaultHooksPath
    )
    ++ map hooksFor declarations;
in
lib.zipAttrsWith (_: values: lib.concatLists values) hookSets
