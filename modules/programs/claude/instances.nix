{
  config,
  lib,
  pkgs,
}:
let
  cfg = config.programs.claude-code;
  syncLib = import ../ai-agents/sync.nix { inherit lib; };
  jsonFormat = pkgs.formats.json { };
  selectSync =
    instanceName: resource:
    syncLib.select "programs.claude-code.instances.${instanceName}.sync.${resource}"
      cfg.instances.${instanceName}.sync.${resource};

  instanceResources = lib.mapAttrs (
    name: _:
    let
      mcpServers = lib.filterAttrs (
        serverName: _: !(builtins.elem serverName (cfg.settings.disabledMcpjsonServers or [ ]))
      ) (selectSync name "mcpServers" cfg.mcpServers);
    in
    {
      skills = selectSync name "skills" cfg.skills;
      agents = selectSync name "agents" (
        lib.genAttrs cfg.agentNames (agentName: "${cfg.agentsDir}/${agentName}.md")
      );
      inherit mcpServers;
      mcpPlugin = pkgs.runCommand "claude-code-${name}-mcp" { } ''
        install -Dm444 ${jsonFormat.generate "plugin.json" { name = cfg.mcpPluginName; }} \
          "$out/.claude-plugin/plugin.json"
        install -Dm444 ${jsonFormat.generate "mcp.json" { inherit mcpServers; }} \
          "$out/.mcp.json"
      '';
    }
  ) cfg.instances;

  nodeOnly = pkgs.runCommand "nodejs-24-node-only" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.nodejs_24}/bin/node $out/bin/node
  '';

  wrappedPackage = pkgs.symlinkJoin (
    {
      inherit (cfg.package) name;
      paths = [ cfg.package ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        rm "$out/bin/claude"
        makeWrapper ${cfg.package}/bin/claude "$out/bin/claude" \
          --prefix PATH : ${lib.makeBinPath ([ nodeOnly ] ++ cfg.extraPath)}
      '';
      meta = cfg.package.meta or { };
    }
    // lib.optionalAttrs (cfg.package ? version) { inherit (cfg.package) version; }
  );

  instancePackages = lib.mapAttrs (
    name: instance:
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      umask 077

      export CLAUDE_CONFIG_DIR=${lib.escapeShellArg "${config.home.homeDirectory}/${instance.home}"}
      ${pkgs.coreutils}/bin/mkdir -p "$CLAUDE_CONFIG_DIR"

      exec ${pkgs.state-get}/bin/state-run ${lib.escapeShellArg name} \
        ${wrappedPackage}/bin/claude ${
          lib.optionalString (instanceResources.${name}.mcpServers != { }) (
            lib.escapeShellArgs [
              "--plugin-dir"
              (toString instanceResources.${name}.mcpPlugin)
            ]
          )
        } "$@"
    ''
  ) cfg.instances;

in
{
  inherit instanceResources wrappedPackage instancePackages;
}
