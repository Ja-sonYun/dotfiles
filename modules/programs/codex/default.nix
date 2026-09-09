{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.codex;
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
  activeManagedSettings = if cfg.enable then managedSettings else { };
  baseManagedFragment = tomlFormat.generate "codex-managed-settings.toml" activeManagedSettings;
  managedFragment =
    if !cfg.enable || cfg.agentsDir == null then
      baseManagedFragment
    else
      pkgs.runCommandLocal "codex-managed-settings.toml" { } ''
        ${pkgs.yq-go}/bin/yq eval-all \
          --input-format=toml \
          --output-format=toml \
          '. as $item ireduce ({}; . * $item)' \
          ${baseManagedFragment} \
          ${cfg.agentsDir}/agents.toml \
          > "$out"
      '';

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
    exec ${cfg.package}/bin/codex \
      ${wrappedArgs} \
      --config "projects.\"$PWD\".trust_level=\"trusted\"" \
      "$@"
  '';

  primaryPackage = pkgs.writeShellScriptBin cfg.defaultProfileName ''
    export CODEX_HOME=${lib.escapeShellArg "${config.home.homeDirectory}/.codex"}
    exec ${wrappedPackage}/bin/codex "$@"
  '';

  instancePackages = lib.mapAttrs (
    name: instance:
    let
      package = if instance.shareWith == null then cfg.package else wrappedPackage;
    in
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
      exec ${package}/bin/codex \
        --config 'cli_auth_credentials_store="file"' \
        "$@"
    ''
  ) cfg.instances;
in
{
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
      description = "Packages added to Codex's PATH.";
    };

    defaultProfileName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      description = "Command name for the primary Codex profile.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            home = lib.mkOption {
              type = lib.types.str;
              description = "Instance home directory relative to the user's home.";
            };

            shareWith = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Codex home to link missing entries from, except auth.json, relative to the user's home. Null uses an independent home without personal settings.";
            };
          };
        }
      );
      default = { };
      description = "Additional Codex commands with separate file-based authentication.";
    };

    settings = lib.mkOption {
      inherit (tomlFormat) type;
      default = { };
      description = "Codex TOML settings.";
    };

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Content for ~/.codex/AGENTS.md.";
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

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Skill directories linked into ~/.codex/skills.";
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = "Rule files written into ~/.codex/rules.";
    };
  };

  config = lib.mkMerge [
    {
      home.activation.codexConfigMerge = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
      '';
    }
    (lib.mkIf cfg.enable {
      programs.state.commands.codex = {
        key = "defaults.codex";
        default = cfg.defaultProfileName;
        choices = {
          ${cfg.defaultProfileName} = "${primaryPackage}/bin/${cfg.defaultProfileName}";
        }
        // lib.mapAttrs (name: package: "${package}/bin/${name}") instancePackages;
      };

      home.packages = [ primaryPackage ] ++ lib.attrValues instancePackages;

      assertions = [
        {
          assertion =
            cfg.defaultProfileName != "codex" && !(builtins.hasAttr cfg.defaultProfileName cfg.instances);
          message = "programs.codex.defaultProfileName must differ from codex and additional instance names.";
        }
        {
          assertion = settingsSecrets.invalidSecretPaths == [ ];
          message = "programs.codex.settings contains invalid _secret values at: ${lib.concatStringsSep ", " settingsSecrets.invalidSecretPaths}.";
        }
        {
          assertion = flagSecrets.secretPaths == [ ];
          message = "programs.codex.settings only supports _secret in settings merged into ~/.codex/config.toml.";
        }
      ];

      home.file =
        lib.optionalAttrs (cfg.context != null) {
          ".codex/AGENTS.md".text = cfg.context;
        }
        // lib.mapAttrs' (
          name: source: lib.nameValuePair ".codex/skills/${name}" { inherit source; }
        ) cfg.skills
        // lib.mapAttrs' (
          name: text: lib.nameValuePair ".codex/rules/${name}.rules" { inherit text; }
        ) cfg.rules;
    })
  ];
}
