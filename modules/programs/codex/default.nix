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

  mcpFragment = tomlFormat.generate "codex-mcp-servers.toml" { mcp_servers = rawMcpServers; };

  mcpMergeScript = pkgs.python3.withPackages (p: [ p.tomlkit ]);

  wrappedPackage =
    pkgs.runCommand "${cfg.package.name}-wrapped" { nativeBuildInputs = [ pkgs.makeWrapper ]; }
      ''
        mkdir -p $out/bin
        makeWrapper ${cfg.package}/bin/codex $out/bin/codex \
          --run "set -- --config 'projects.''''\"\$PWD\"''''.trust_level=\"trusted\"'" \
          --add-flag --profile \
          --add-flag ${lib.escapeShellArg cfg.profileName}
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

    profileName = lib.mkOption {
      type = lib.types.str;
      default = "home-manager";
      description = "Codex profile name for managed settings.";
    };

    settings = lib.mkOption {
      inherit (tomlFormat) type;
      default = { };
      description = "Codex profile TOML settings.";
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
    let
      profileTarget = ".codex/${cfg.profileName}.config.toml";
    in
    lib.mkMerge [
      {
        home.packages = [ wrappedPackage ];

        home.file = {
          ${profileTarget}.source = tomlFormat.generate "codex-${cfg.profileName}.config.toml" cfg.settings;
        }
        // lib.optionalAttrs (cfg.context != null) {
          ".codex/AGENTS.md".text = cfg.context;
        }
        // lib.mapAttrs' (
          name: source: lib.nameValuePair ".codex/skills/${name}" { inherit source; }
        ) cfg.skills
        // lib.mapAttrs' (
          name: text: lib.nameValuePair ".codex/rules/${name}.rules" { inherit text; }
        ) cfg.rules;
      }

      (lib.mkIf (cfg.enableMcpIntegration && config.programs.mcp.enable) {
        programs.codex.settings.mcp_servers = transformedMcpServers;

        # base config.toml must stay writable for the GUI, so merge instead of symlinking it
        home.activation.codexMcpMerge = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run mkdir -p "${config.home.homeDirectory}/.codex"
          run ${mcpMergeScript}/bin/python3 ${./merge-config-toml.py} \
            "${config.home.homeDirectory}/.codex/config.toml" ${mcpFragment} \
            "${config.home.homeDirectory}/.codex/.home-manager-mcp-state.json"
        '';
      })
    ]
  );
}
