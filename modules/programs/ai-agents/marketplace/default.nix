{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ai-agents;
  helpers = import ./lib.nix { inherit lib; };
  hooksForPlugin = import ./hooks.nix { inherit helpers lib; };
  mcpNamesForPlugin = import ./mcp.nix { inherit helpers lib; };
  skillsForPlugin = import ./skills.nix { inherit helpers lib pkgs; };
  pluginsForMarketplace = import ./plugins.nix {
    inherit
      helpers
      hooksForPlugin
      lib
      mcpNamesForPlugin
      skillsForPlugin
      ;
  };
  sourceType =
    with lib.types;
    oneOf [
      package
      path
    ];
  pluginEntries = lib.concatLists (lib.mapAttrsToList pluginsForMarketplace cfg.marketplaces);
  skillEntries = lib.concatMap (plugin: plugin.skills) pluginEntries;
  skillNames = map (entry: entry.name) skillEntries;
  duplicateNames = builtins.filter (name: lib.count (candidate: candidate == name) skillNames > 1) (
    lib.unique skillNames
  );
  duplicateDetails = lib.concatMapStringsSep "; " (
    name:
    let
      origins = map (entry: "${entry.marketplace}:${entry.pluginName}/${entry.skillName}") (
        builtins.filter (entry: entry.name == name) skillEntries
      );
    in
    "${name} (${lib.concatStringsSep ", " origins})"
  ) duplicateNames;
  marketplaceSkills =
    if duplicateNames != [ ] then
      throw "programs.ai-agents.marketplaces produces duplicate skills: ${duplicateDetails}."
    else
      builtins.listToAttrs (map (entry: lib.nameValuePair entry.name entry.value) skillEntries);
  marketplaceHooks = lib.zipAttrsWith (_: values: lib.concatLists values) (
    map (plugin: plugin.hooks) pluginEntries
  );
  missingMcpDependencies = builtins.filter (dependency: dependency.names != [ ]) (
    map (plugin: {
      inherit (plugin) marketplace pluginName;
      names = builtins.filter (name: !builtins.hasAttr name cfg.mcp.servers) plugin.requiredMcpNames;
    }) pluginEntries
  );
  missingMcpDetails = lib.concatMapStringsSep "\n" (
    dependency:
    "  ${dependency.marketplace}/${dependency.pluginName}: ${lib.concatStringsSep ", " dependency.names}"
  ) missingMcpDependencies;
in
{
  options.programs.ai-agents.marketplaces = lib.mkOption {
    type = lib.types.attrsOf sourceType;
    default = { };
    description = ''
      Claude-style marketplace paths or packages whose skills and command hooks are shared by AI agents
      and whose MCP dependencies must be configured explicitly.
      Package sources require import-from-derivation; use a flake input outPath when IFD is disabled.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.marketplaces != { }) {
    assertions = [
      {
        assertion = missingMcpDependencies == [ ];
        message = "programs.ai-agents.marketplaces requires unconfigured MCP servers:\n${missingMcpDetails}";
      }
    ];
    programs.ai-agents = {
      hooks = lib.mapAttrs (_: blocks: lib.mkAfter blocks) marketplaceHooks;
      skills = lib.mapAttrs (_: lib.mkDefault) marketplaceSkills;
    };
  };
}
