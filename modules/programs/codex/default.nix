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
    selectSettings managedSettingKeys settings
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
      home.packages = [ wrappedPackage ];

      assertions = [
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
