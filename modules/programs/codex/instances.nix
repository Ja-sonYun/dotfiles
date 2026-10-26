{
  config,
  lib,
  pkgs,
  settings,
}:
let
  cfg = config.programs.codex;
  syncLib = import ../ai-agents/sync.nix { inherit lib; };
  nodeOnly = pkgs.runCommand "nodejs-24-node-only" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.nodejs_24}/bin/node $out/bin/node
  '';

  selectSync =
    instanceName: resource:
    syncLib.select "programs.codex.instances.${instanceName}.sync.${resource}"
      cfg.instances.${instanceName}.sync.${resource};

  independentInstances = lib.filterAttrs (_: instance: instance.shareWith == null) cfg.instances;

  instanceResources = lib.mapAttrs (
    name: _:
    let
      mcpServers = lib.filterAttrs (
        _: server: (server.enabled or true) != false && (server.disabled or false) != true
      ) (selectSync name "mcpServers" (settings.settings.mcp_servers or { }));
      selectedAgents = builtins.attrNames (
        selectSync name "agents" (lib.genAttrs cfg.agentNames (_: null))
      );
    in
    {
      skills = selectSync name "skills" cfg.skills;
      fragment = settings.mkManagedFragment name (
        settings.managedSettings
        // {
          mcp_servers = mcpServers;
        }
      ) selectedAgents;
    }
  ) independentInstances;

  wrappedPackage = pkgs.writeShellScriptBin "codex" ''
    export PATH=${lib.makeBinPath ([ nodeOnly ] ++ cfg.extraPath)}:$PATH
    ${lib.optionalString cfg.trustCurrentDirectory ''
      project_key="$(${pkgs.jq}/bin/jq -cn --arg path "$PWD" '$path')"
    ''}
    exec ${cfg.package}/bin/codex \
      ${settings.wrappedArgs} \
      ${lib.optionalString cfg.trustCurrentDirectory ''--config "projects.$project_key.trust_level=\"trusted\""''} \
      "$@"
  '';

  instancePackages = lib.mapAttrs (
    name: instance:
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      umask 077

      export CODEX_HOME=${lib.escapeShellArg "${config.home.homeDirectory}/${instance.home}"}
      ${pkgs.coreutils}/bin/mkdir -p "$CODEX_HOME"
      ${lib.optionalString (instance.shareWith != null) ''
        shared_home=${lib.escapeShellArg "${config.home.homeDirectory}/${instance.shareWith}"}
        shopt -s dotglob nullglob
        for source in "$shared_home"/*; do
          entry="''${source##*/}"
          if [[ "$entry" == auth.json ]]; then
            continue
          fi
          target="$CODEX_HOME/$entry"
          if [[ ! -e "$target" && ! -L "$target" ]]; then
            ${pkgs.coreutils}/bin/ln -s "$source" "$target"
          fi
        done
      ''}
      exec ${pkgs.state-get}/bin/state-run ${lib.escapeShellArg name} ${wrappedPackage}/bin/codex \
        ${
          lib.optionalString (instance.home != ".codex") "--config 'cli_auth_credentials_store=\"file\"'"
        } \
        "$@"
    ''
  ) cfg.instances;

in
{
  inherit
    instanceResources
    wrappedPackage
    instancePackages
    independentInstances
    ;
}
