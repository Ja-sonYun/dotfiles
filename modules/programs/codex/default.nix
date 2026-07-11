{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.codex;
  tomlFormat = pkgs.formats.toml { };

  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];

  mkDefaultTomlValue =
    value:
    if builtins.isAttrs value && !lib.isDerivation value then
      lib.mapAttrs (_: mkDefaultTomlValue) value
    else
      lib.mkDefault value;

  rawMcpServers = lib.mapAttrs (
    name: server:
    lib.hm.mcp.transformMcpServer {
      inherit server;
      exclude = [
        "headers"
        "type"
      ];
      extraTransforms = [
        (s: s // lib.optionalAttrs (s.headers or { } != { }) { http_headers = s.headers; })
        lib.hm.mcp.addType
        (lib.hm.mcp.wrapEnvFilesCommand { inherit pkgs name; })
      ];
    }
  ) config.programs.mcp.servers;

  transformedMcpServers = lib.mapAttrs (_: mkDefaultTomlValue) rawMcpServers;

  managedSettingKeys = [
    "default_permissions"
    "features"
    "hooks"
    "mcp_servers"
    "model_providers"
    "tui"
  ];

  selectSettings = keys: lib.filterAttrs (name: _: builtins.elem name keys);

  permissions = cfg.settings.permissions or { };
  managedSettings =
    selectSettings managedSettingKeys cfg.settings
    // lib.optionalAttrs (permissions ? managed) {
      permissions.managed = permissions.managed;
    };
  flagSettings =
    removeAttrs cfg.settings (managedSettingKeys ++ [ "permissions" ])
    // lib.optionalAttrs (removeAttrs permissions [ "managed" ] != { }) {
      permissions = removeAttrs permissions [ "managed" ];
    };

  settingsSecrets = pkgs.tool.secretSettings cfg.settings;
  flagSecrets = pkgs.tool.secretSettings flagSettings;
  managedFragment = tomlFormat.generate "codex-managed-settings.toml" managedSettings;

  configMergePython = pkgs.python3.withPackages (p: [ p.tomlkit ]);

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

    enableMcpIntegration = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to integrate shared programs.mcp.servers into Codex.";
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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
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

        home.activation.codexConfigMerge = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run mkdir -p "${config.home.homeDirectory}/.codex"
          run ${configMergePython}/bin/python3 ${./merge-config-toml.py} \
            "${config.home.homeDirectory}/.codex/config.toml" ${managedFragment} \
            "${config.home.homeDirectory}/.codex/.home-manager-mcp-state.json" \
            "${config.home.homeDirectory}/.codex/.home-manager-model-provider-state.json"
        '';
      }

      (lib.mkIf (cfg.enableMcpIntegration && config.programs.mcp.enable) {
        programs.codex.settings.mcp_servers = transformedMcpServers;
      })
    ]
  );
}
