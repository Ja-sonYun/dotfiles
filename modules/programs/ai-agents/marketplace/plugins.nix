{
  helpers,
  hooksForPlugin,
  lib,
  mcpNamesForPlugin,
  skillsForPlugin,
}:
let
  inherit (helpers)
    fail
    readJson
    relativeSegments
    validName
    ;
  supportedComponents = [
    "hooks"
    "mcpServers"
    "skills"
  ];

  pluginManifestFor =
    marketplace: pluginName: pluginRoot:
    let
      path = "${pluginRoot}/.claude-plugin/plugin.json";
      value = readJson marketplace "plugin `${pluginName}` manifest" path;
    in
    if !builtins.pathExists path then
      null
    else if builtins.isAttrs value then
      value
    else
      fail marketplace "plugin `${pluginName}` manifest must be a JSON object.";

  pluginForMarketplace =
    marketplace: marketplaceSource: marketplacePluginRoot: pluginIndex: plugin:
    let
      location = "plugin at index ${toString pluginIndex}";
      pluginName =
        if builtins.isAttrs plugin && plugin ? name && builtins.isString plugin.name then
          plugin.name
        else
          fail marketplace "${location} must have a string `name`.";
      pluginSource =
        if builtins.isAttrs plugin && plugin ? source && builtins.isString plugin.source then
          plugin.source
        else
          fail marketplace "${location} `${pluginName}` must use a relative string `source`; external plugin sources are unsupported.";
      sourceSegments = relativeSegments marketplace "plugin `${pluginName}` source" (
        marketplacePluginRoot == null
      ) pluginSource;
      rootSegments = if marketplacePluginRoot == null then [ ] else marketplacePluginRoot;
      combinedSegments = rootSegments ++ sourceSegments;
      relativeSource = lib.concatStringsSep "/" combinedSegments;
      pluginRoot =
        if relativeSource == "" then marketplaceSource else "${marketplaceSource}/${relativeSource}";
      pluginAtMarketplaceRoot = combinedSegments == [ ];
      pluginFiles =
        if !validName pluginName then
          fail marketplace "plugin `${pluginName}` must use lowercase kebab-case."
        else if !builtins.pathExists pluginRoot then
          fail marketplace "plugin `${pluginName}` source `${pluginSource}` does not exist."
        else
          builtins.readDir pluginRoot;
      pluginManifest = pluginManifestFor marketplace pluginName pluginRoot;
      strict =
        if !(plugin ? strict) then
          true
        else if builtins.isBool plugin.strict then
          plugin.strict
        else
          fail marketplace "plugin `${pluginName}` `strict` must be a boolean.";
      manifestComponents =
        if pluginManifest == null then
          [ ]
        else
          builtins.filter (component: builtins.hasAttr component pluginManifest) supportedComponents;
      declarationsFor =
        component:
        if !strict && manifestComponents != [ ] then
          fail marketplace "plugin `${pluginName}` has conflicting supported component declarations with `strict = false`: ${lib.concatStringsSep ", " manifestComponents}."
        else
          lib.optional (
            strict && pluginManifest != null && builtins.hasAttr component pluginManifest
          ) pluginManifest.${component}
          ++ lib.optional (builtins.hasAttr component plugin) plugin.${component};
      useDefaultFor =
        component:
        if strict then
          pluginManifest == null || !(builtins.hasAttr component pluginManifest)
        else
          !(builtins.hasAttr component plugin);
    in
    {
      inherit marketplace pluginName;
      hooks = hooksForPlugin marketplace pluginName pluginRoot (useDefaultFor "hooks") (
        declarationsFor "hooks"
      );
      requiredMcpNames =
        mcpNamesForPlugin marketplace pluginName pluginRoot (useDefaultFor "mcpServers")
          (declarationsFor "mcpServers");
      skills =
        skillsForPlugin marketplace pluginName pluginRoot pluginFiles pluginAtMarketplaceRoot
          (useDefaultFor "skills")
          (declarationsFor "skills");
    };
in
marketplace: source:
let
  manifestPath = "${source}/.claude-plugin/marketplace.json";
  manifest = readJson marketplace "manifest" manifestPath;
  marketplacePluginRoot =
    if !(builtins.isAttrs manifest) || !(manifest ? metadata) then
      null
    else if !builtins.isAttrs manifest.metadata then
      fail marketplace "marketplace.json `metadata` must be a JSON object."
    else if !(manifest.metadata ? pluginRoot) then
      null
    else
      relativeSegments marketplace "marketplace.json `metadata.pluginRoot`" true
        manifest.metadata.pluginRoot;
  plugins =
    if builtins.isAttrs manifest && manifest ? plugins && builtins.isList manifest.plugins then
      manifest.plugins
    else
      fail marketplace "marketplace.json must contain a `plugins` list.";
in
lib.imap0 (pluginForMarketplace marketplace source marketplacePluginRoot) plugins
