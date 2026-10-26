{
  config,
  lib,
  pkgs,
}:
let
  cfg = config.programs.codex;
  jsonFormat = pkgs.formats.json { };
  tomlFormat = pkgs.formats.toml { };
  codexConfigFile = "${config.home.homeDirectory}/.codex/config.toml";

  managedSettingKeys = [
    "agents"
    "default_permissions"
    "features"
    "hooks"
    "mcp_servers"
    "model_providers"
    "tui"
    "web_search"
  ];
  mirroredSettingKeys = [
    "model"
    "model_provider"
    "model_verbosity"
    "model_reasoning_effort"
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
      baseManagedFragment =
        if cfg.enable && cfg.settingsTransform != null then
          pkgs.runCommandLocal "codex-${name}-managed-settings.toml" { } ''
            set -euo pipefail
            ${cfg.settingsTransform} \
              < ${jsonFormat.generate "codex-${name}-settings.json" instanceSettings} \
              | ${pkgs.yq-go}/bin/yq --input-format=json --output-format=toml '.' > "$out"
          ''
        else
          tomlFormat.generate "codex-${name}-managed-settings.toml" (
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

  sharedFiles =
    home:
    lib.optionalAttrs (cfg.context != null) {
      "${home}/AGENTS.md" = {
        text = cfg.context;
      };
    }
    // lib.mapAttrs' (
      name: text: lib.nameValuePair "${home}/rules/${name}.rules" { inherit text; }
    ) cfg.rules
    // lib.mapAttrs' (
      name: source: lib.nameValuePair "${home}/rules/${name}.rules" { inherit source; }
    ) cfg.rulesSources;
in
{
  inherit
    codexConfigFile
    managedFragment
    configMerge
    settingsSecrets
    flagSecrets
    sharedFiles
    settings
    managedSettings
    mkManagedFragment
    wrappedArgs
    ;
}
