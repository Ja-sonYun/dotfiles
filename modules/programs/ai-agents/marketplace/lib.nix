{ lib }:
let
  validName = name: builtins.match "[a-z0-9]+(-[a-z0-9]+)*" name != null;
  fail = marketplace: message: throw "programs.ai-agents.marketplaces.${marketplace}: ${message}";

  readJson =
    marketplace: context: path:
    let
      parsed =
        if !builtins.pathExists path then
          fail marketplace "${context} `${path}` does not exist."
        else
          builtins.tryEval (builtins.fromJSON (builtins.readFile path));
    in
    if parsed.success then parsed.value else fail marketplace "${context} `${path}` is not valid JSON.";

  relativeSegments =
    marketplace: context: requireDot: path:
    let
      relativePath = lib.removePrefix "./" path;
      pathSegments = builtins.filter (segment: segment != "" && segment != ".") (
        lib.splitString "/" relativePath
      );
    in
    if !builtins.isString path then
      fail marketplace "${context} must be a string."
    else if lib.hasPrefix "/" path || (requireDot && path != "." && !lib.hasPrefix "./" path) then
      fail marketplace "${context} must be a relative `./...` path."
    else if builtins.elem ".." pathSegments then
      fail marketplace "${context} must not contain `..`."
    else
      pathSegments;

  pluginRelativePath =
    marketplace: pluginName: context: pluginRoot: allowRoot: path:
    let
      segments = relativeSegments marketplace "plugin `${pluginName}` ${context}" (!allowRoot) path;
      relativePath = lib.concatStringsSep "/" segments;
    in
    if relativePath == "" then pluginRoot else "${pluginRoot}/${relativePath}";
in
{
  inherit
    fail
    pluginRelativePath
    readJson
    relativeSegments
    validName
    ;
}
