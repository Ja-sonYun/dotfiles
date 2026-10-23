{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.antigravity-cli;
  syncLib = import ../ai-agents/sync.nix { inherit lib; };
  jsonFormat = pkgs.formats.json { };
  selectedAgents = syncLib.select "programs.antigravity-cli.sync.agents" cfg.sync.agents (
    lib.genAttrs cfg.agentNames (name: "${cfg.agentsDir}/${name}.md")
  );
  baseSettingsFile = jsonFormat.generate "antigravity-cli-settings.json" (
    lib.recursiveUpdate (lib.optionalAttrs (cfg.permissions != null) {
      permissions = lib.filterAttrs (_: value: value != null) cfg.permissions;
    }) (removeAttrs cfg.settings [ "mcpServers" ])
  );
  settingsFile =
    if cfg.settingsTransform == null then
      baseSettingsFile
    else
      pkgs.runCommandLocal "antigravity-cli-settings.json" { } ''
        ${cfg.settingsTransform} < ${baseSettingsFile} > "$out"
      '';
in
{
  options.programs.antigravity-cli = {
    sync = syncLib.mkOptions true;

    mcpServers = lib.mkOption {
      apply = syncLib.select "programs.antigravity-cli.sync.mcpServers" cfg.sync.mcpServers;
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Directory containing native Antigravity agents.";
    };

    agentNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Available agent names.";
    };

    package = lib.mkOption {
      apply =
        basePackage:
        if basePackage == null || cfg.lifecycleObserver == null then
          basePackage
        else
          pkgs.runCommand "antigravity-cli-observed" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
            mkdir -p "$out/bin"
            makeWrapper ${lib.getExe cfg.lifecycleObserver} "$out/bin/agy" \
              --add-flags ${basePackage}/bin/agy
          '';
    };
    hooks = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = { };
      description = "Named hook sets in Antigravity's native hooks.json format.";
    };
    lifecycleObserver = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Launcher observing CLI lifecycle; receives the CLI executable followed by its arguments.";
    };
    settingsTransform = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Build-time settings transformer (JSON stdin/stdout) for native immutable settings.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = selectedAgents == { } || cfg.agentsDir != null;
        message = "programs.antigravity-cli selected agents require agentsDir.";
      }
      {
        assertion = cfg.lifecycleObserver == null || cfg.package != null;
        message = "programs.antigravity-cli.lifecycleObserver requires a non-null package.";
      }
      {
        assertion = cfg.settingsTransform == null || (!cfg.mutableSettings && !cfg.useLegacyGeminiConfig);
        message = "programs.antigravity-cli.settingsTransform requires native immutable settings.";
      }
    ];

    home.file = {
      ".gemini/config/hooks.json" = lib.mkIf (cfg.hooks != { }) {
        force = true;
        source = jsonFormat.generate "antigravity-hooks.json" cfg.hooks;
      };
      ".gemini/antigravity-cli/settings.json" =
        lib.mkIf
          (
            !cfg.mutableSettings
            && !cfg.useLegacyGeminiConfig
            && (cfg.settings != { } || cfg.settingsTransform != null)
          )
          {
            force = true;
            source = lib.mkIf (cfg.settingsTransform != null) (lib.mkForce settingsFile);
          };
      ".gemini/config/mcp_config.json" = lib.mkIf (!cfg.mutableSettings && !cfg.useLegacyGeminiConfig) {
        force = true;
        source = lib.mkIf (cfg.mcpServers == { } && (cfg.settings.mcpServers or { }) == { }) (
          jsonFormat.generate "antigravity-mcp.json" { mcpServers = { }; }
        );
      };
    }
    // lib.mapAttrs' (
      name: source: lib.nameValuePair ".gemini/config/agents/${name}.md" { inherit source; }
    ) selectedAgents;
  };
}
