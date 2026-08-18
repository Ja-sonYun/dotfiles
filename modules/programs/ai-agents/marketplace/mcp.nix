{
  helpers,
  lib,
}:
let
  inherit (helpers) fail pluginRelativePath readJson;
in
marketplace: pluginName: pluginRoot: useDefault: declarations:
let
  defaultMcpPath = "${pluginRoot}/.mcp.json";
  readMcpFile =
    path:
    let
      value = readJson marketplace "plugin `${pluginName}` MCP configuration" path;
    in
    if builtins.isAttrs value && value ? mcpServers && builtins.isAttrs value.mcpServers then
      value.mcpServers
    else
      fail marketplace "plugin `${pluginName}` MCP configuration must contain an `mcpServers` object.";
  serversFor =
    declaration:
    if builtins.isAttrs declaration then
      declaration
    else if builtins.isString declaration then
      readMcpFile (
        pluginRelativePath marketplace pluginName "MCP configuration path" pluginRoot false declaration
      )
    else
      fail marketplace "plugin `${pluginName}` `mcpServers` must be an object or relative path.";
  serverSets =
    lib.optional (useDefault && builtins.pathExists defaultMcpPath) (readMcpFile defaultMcpPath)
    ++ map serversFor declarations;
in
lib.unique (lib.concatMap builtins.attrNames serverSets)
