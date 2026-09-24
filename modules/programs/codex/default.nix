{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.codex;
  syncLib = import ../ai-agents/sync.nix { inherit lib; };
  tomlFormat = pkgs.formats.toml { };
  nodeOnly = pkgs.runCommand "nodejs-24-node-only" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.nodejs_24}/bin/node $out/bin/node
  '';

  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];

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
      ) (selectSync name "mcpServers" (settings.mcp_servers or { }));
      selectedAgents = builtins.attrNames (
        selectSync name "agents" (lib.genAttrs cfg.agentNames (_: null))
      );
    in
    {
      skills = selectSync name "skills" cfg.skills;
      fragment = mkManagedFragment name (
        managedSettings
        // {
          mcp_servers = mcpServers;
        }
      ) selectedAgents;
    }
  ) independentInstances;

  codexConfigFile = "${config.home.homeDirectory}/.codex/config.toml";

  managedSettingKeys = [
    "agents"
    "default_permissions"
    "features"
    "hooks"
    "mcp_servers"
    "model_providers"
    "tui"
  ];
  mirroredSettingKeys = [
    "model"
    "model_provider"
    "model_verbosity"
    "model_reasoning_effort"
    "web_search"
  ];

  selectSettings = keys: lib.filterAttrs (name: _: builtins.elem name keys);

  configuredDeveloperInstructions = cfg.settings.developer_instructions or "";
  developerInstructions = lib.concatStringsSep "\n\n" (
    lib.filter (instructions: instructions != "") [
      cfg.customInstructions
      configuredDeveloperInstructions
    ]
  );
  settings =
    cfg.settings
    // lib.optionalAttrs (developerInstructions != "") {
      developer_instructions = developerInstructions;
    };
  permissions = settings.permissions or { };
  managedSettings =
    selectSettings (managedSettingKeys ++ mirroredSettingKeys) settings
    // lib.optionalAttrs (permissions ? managed) {
      permissions.managed = permissions.managed;
    };
  flagSettings =
    removeAttrs settings (managedSettingKeys ++ [ "permissions" ])
    // lib.optionalAttrs (removeAttrs permissions [ "managed" ] != { }) {
      permissions = removeAttrs permissions [ "managed" ];
    };

  settingsSecrets = pkgs.tool.secretSettings settings;
  flagSecrets = pkgs.tool.secretSettings flagSettings;
  mkManagedFragment =
    name: instanceSettings: selectedAgents:
    let
      baseManagedFragment = tomlFormat.generate "codex-${name}-managed-settings.toml" (
        if cfg.enable then instanceSettings else { }
      );
      agentSelection = lib.concatMapStringsSep " or " (
        agentName: ".key == ${builtins.toJSON agentName}"
      ) selectedAgents;
    in
    if !cfg.enable || selectedAgents == [ ] || cfg.agentsDir == null then
      baseManagedFragment
    else
      pkgs.runCommandLocal "codex-${name}-managed-settings.toml" { } ''
        ${pkgs.yq-go}/bin/yq eval-all \
          --input-format=toml \
          --output-format=toml \
          ${lib.escapeShellArg ''
            select(fileIndex == 0) *
            (select(fileIndex == 1) | .agents |= with_entries(select(${agentSelection})))
          ''} \
          ${baseManagedFragment} \
          ${cfg.agentsDir}/agents.toml \
          > "$out"
      '';
  managedFragment = mkManagedFragment "default" managedSettings cfg.agentNames;

  configMerge = pkgs.uv.asPackage {
    name = "merge-codex-config";
    root = ./.;
    entrypoint = "merge-config-toml:main";
  };

  quoteKey = key: if builtins.match "[A-Za-z0-9_-]+" key == null then builtins.toJSON key else key;

  flattenSettings =
    path: value:
    if builtins.isAttrs value && !lib.isDerivation value then
      lib.concatLists (lib.mapAttrsToList (name: child: flattenSettings (path ++ [ name ]) child) value)
    else
      [
        {
          key = lib.concatMapStringsSep "." quoteKey path;
          inherit value;
        }
      ];

  flagArgs = lib.concatMap (setting: [
    "--config"
    "${setting.key}=${builtins.toJSON setting.value}"
  ]) (flattenSettings [ ] flagSettings);

  wrappedArgs = lib.escapeShellArgs flagArgs;

  wrappedPackage = pkgs.writeShellScriptBin "codex" ''
    export PATH=${lib.makeBinPath ([ nodeOnly ] ++ cfg.extraPath)}:$PATH
    ${lib.optionalString cfg.trustCurrentDirectory ''
      project_key="$(${pkgs.jq}/bin/jq -cn --arg path "$PWD" '$path')"
    ''}
    exec ${cfg.package}/bin/codex \
      ${wrappedArgs} \
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

  sharedFiles =
    home:
    lib.optionalAttrs (cfg.context != null) {
      "${home}/AGENTS.md" = {
        text = cfg.context;
      };
    }
    // lib.mapAttrs' (
      name: text: lib.nameValuePair "${home}/rules/${name}.rules" { inherit text; }
    ) cfg.rules;
in
{
  imports = [ ../state ];

  disabledModules = [ "programs/codex" ];

  options.programs.codex = {
    enable = lib.mkEnableOption "Codex";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.codex;
      description = "Codex package to install.";
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages added to every Codex instance's PATH.";
    };

    trustCurrentDirectory = lib.mkEnableOption "trusting the current directory when starting Codex";

    defaultProfileName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      description = "Declared instance selected when ~/.state.toml is first created.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              home = lib.mkOption {
                type = lib.types.str;
                description = "Instance home directory relative to the user's home.";
              };

              shareWith = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Codex home to link missing entries from, relative to the user's home.
                  Excludes only auth.json. Uses the source home's skills, MCP servers, and agents;
                  this instance's sync selections do not apply.
                  Null keeps runtime data independent. Declared settings are shared by every instance.
                '';
              };

              sync = syncLib.mkOptions (name == cfg.defaultProfileName);
            };
          }
        )
      );
      default = { };
      description = "Codex commands with separate user profiles.";
    };

    settings = lib.mkOption {
      inherit (tomlFormat) type;
      default = { };
      description = "Codex TOML settings shared by every instance, including hooks and permissions.";
    };

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "AGENTS.md content shared by every instance.";
    };

    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Instructions prepended to Codex developer instructions.";
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Directory containing adapted Codex custom agents.";
    };

    agentNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Selectable custom-agent names matching entries in agentsDir/agents.toml.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Skill directory catalog selected by each instance's sync settings.";
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = "Rule files shared in every instance's rules directory.";
    };
  };

  config = lib.mkMerge [
    {
      home.activation.codexConfigMerge = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        if cfg.instances == { } then
          ''
            ${lib.optionalString cfg.enable ''
              run mkdir -p "${config.home.homeDirectory}/.codex"
              run ${configMerge}/bin/merge-codex-config \
                "${codexConfigFile}" ${managedFragment}
            ''}
            ${lib.optionalString (!cfg.enable) ''
              if [[ -f "${codexConfigFile}" ]]; then
                run ${configMerge}/bin/merge-codex-config \
                  "${codexConfigFile}" ${managedFragment}
              fi
            ''}
          ''
        else
          lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: instance:
              let
                instanceHome = "${config.home.homeDirectory}/${instance.home}";
              in
              ''
                ${lib.optionalString cfg.enable ''
                  run ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg instanceHome}
                ''}
                if ${
                  if cfg.enable then "true" else "false"
                } || [[ -f ${lib.escapeShellArg "${instanceHome}/config.toml"} ]]; then
                  run ${configMerge}/bin/merge-codex-config \
                    ${lib.escapeShellArg "${instanceHome}/config.toml"} ${instanceResources.${name}.fragment}
                fi
              ''
            ) independentInstances
          )
      );
    }
    (lib.mkIf cfg.enable {
      programs.state.commands.codex = lib.mkIf (cfg.instances != { }) {
        key = "defaults.codex";
        default = cfg.defaultProfileName;
        choices = lib.mapAttrs (name: package: "${package}/bin/${name}") instancePackages;
      };

      home.packages =
        if cfg.instances == { } then [ wrappedPackage ] else lib.attrValues instancePackages;

      assertions = [
        {
          assertion = cfg.instances == { } || builtins.hasAttr cfg.defaultProfileName cfg.instances;
          message = "programs.codex.defaultProfileName must name a declared instance.";
        }
        {
          assertion = !(builtins.hasAttr "codex" cfg.instances);
          message = "programs.codex.instances must not use the reserved command name codex.";
        }
        {
          assertion = cfg.agentNames == [ ] || cfg.agentsDir != null;
          message = "programs.codex.agentNames requires agentsDir.";
        }
        {
          assertion = settingsSecrets.invalidSecretPaths == [ ];
          message = "programs.codex.settings contains invalid _secret values at: ${lib.concatStringsSep ", " settingsSecrets.invalidSecretPaths}.";
        }
        {
          assertion = flagSecrets.secretPaths == [ ];
          message = "programs.codex.settings only supports _secret in settings merged into instance config.toml files.";
        }
      ];

      home.file =
        if cfg.instances == { } then
          sharedFiles ".codex"
          // lib.mapAttrs' (
            name: source: lib.nameValuePair ".codex/skills/${name}" { inherit source; }
          ) cfg.skills
        else
          lib.concatMapAttrs (
            instanceName: instance:
            sharedFiles instance.home
            // lib.mapAttrs' (
              name: source: lib.nameValuePair "${instance.home}/skills/${name}" { inherit source; }
            ) instanceResources.${instanceName}.skills
          ) independentInstances;
    })
  ];
}
