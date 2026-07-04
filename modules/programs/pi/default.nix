{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi;
  jsonFormat = pkgs.formats.json { };

  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];

  agentDir = ".pi/agent";

  transformedMcpServers = lib.mapAttrs (
    name: server:
    lib.hm.mcp.transformMcpServer {
      inherit server;
      exclude = [ "type" ];
      extraTransforms = [
        (lib.hm.mcp.wrapEnvFilesCommand { inherit pkgs name; })
      ];
    }
  ) config.programs.mcp.servers;

  bundledExtensions =
    lib.optional cfg.enableMcpIntegration "${cfg.mcp.package}/extension/index.ts"
    ++ lib.optional cfg.permissions.enable "${cfg.permissions.package}/extension/index.ts";

  finalSettings =
    cfg.settings
    // lib.optionalAttrs (bundledExtensions != [ ]) {
      extensions = (cfg.settings.extensions or [ ]) ++ bundledExtensions;
    };

  # Point at an immutable store copy: extension can neither create (EACCES) nor overwrite it.
  permissionConfigFile = jsonFormat.generate "pi-permission-system-config.json" {
    debug = false;
    yoloMode = false;
  };
  permissionConfigFlag = lib.optionalString cfg.permissions.enable "--set-default PI_PERMISSION_SYSTEM_CONFIG_PATH ${permissionConfigFile}";

  # Secrets are read at launch, not baked, so $(cat) must run in the wrapper.
  wrappedPackage =
    if cfg.envFiles == { } && !cfg.permissions.enable then
      cfg.package
    else
      pkgs.runCommand "${cfg.package.name}-wrapped" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
        mkdir -p $out/bin
        makeWrapper ${cfg.package}/bin/pi $out/bin/pi \
          ${lib.concatStringsSep " \\\n      " (
            lib.optional cfg.permissions.enable permissionConfigFlag
            ++ lib.mapAttrsToList (
              name: file: "--run ${lib.escapeShellArg ''export ${name}="$(cat ${file} 2>/dev/null)"''}"
            ) cfg.envFiles
          )}
      '';
in
{
  options.programs.pi = {
    enable = lib.mkEnableOption "Pi coding agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pi;
      description = "Pi coding agent package to install.";
    };

    envFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        CAPI_KEY = "/run/agenix/capi-key";
      };
      description = ''
        Environment variables exported into the pi process at launch, each read
        at runtime from a file (e.g. an agenix secret path). Readable from
        extensions via process.env.
      '';
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = "Settings written to ~/.pi/agent/settings.json.";
    };

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Content for ~/.pi/agent/AGENTS.md.";
    };

    systemPrompt = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Content for ~/.pi/agent/SYSTEM.md.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Skill directories linked into ~/.pi/agent/skills.";
    };

    extensions = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Extension files/directories linked into ~/.pi/agent/extensions.";
    };

    enableMcpIntegration = lib.mkEnableOption "the pi-mcp-adapter extension fed by shared programs.mcp.servers";

    mcp = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.pi-extensions.mcp-adapter;
        description = "pi-mcp-adapter extension package.";
      };

      settings = lib.mkOption {
        inherit (jsonFormat) type;
        default = { };
        example = {
          toolPrefix = "server";
          idleTimeout = 10;
          directTools = false;
        };
        description = "The `settings` block of ~/.pi/agent/mcp.json.";
      };
    };

    permissions = {
      enable = lib.mkEnableOption "the pi-permission-system extension";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.pi-extensions.permission-system;
        description = "pi-permission-system extension package.";
      };

      config = lib.mkOption {
        inherit (jsonFormat) type;
        default = { };
        example = {
          defaultPolicy = {
            tools = "ask";
            bash = "ask";
            mcp = "ask";
            skills = "ask";
          };
          bash."git status" = "allow";
        };
        description = "Permission policy written to the extension's pi-permissions.jsonc.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [ wrappedPackage ];

        home.file = {
          "${agentDir}/settings.json".source = jsonFormat.generate "pi-settings.json" finalSettings;
        }
        // lib.optionalAttrs (cfg.context != null) {
          "${agentDir}/AGENTS.md".text = cfg.context;
        }
        // lib.optionalAttrs (cfg.systemPrompt != null) {
          "${agentDir}/SYSTEM.md".text = cfg.systemPrompt;
        }
        // lib.mapAttrs' (
          name: source: lib.nameValuePair "${agentDir}/skills/${name}" { inherit source; }
        ) cfg.skills
        // lib.mapAttrs' (
          name: source: lib.nameValuePair "${agentDir}/extensions/${name}" { inherit source; }
        ) cfg.extensions;
      }

      (lib.mkIf (cfg.enableMcpIntegration && config.programs.mcp.enable) {
        home.file."${agentDir}/mcp.json".source = jsonFormat.generate "pi-mcp.json" {
          settings = cfg.mcp.settings;
          mcpServers = transformedMcpServers;
        };
      })

      (lib.mkIf cfg.permissions.enable {
        home.file."${agentDir}/pi-permissions.jsonc".source =
          jsonFormat.generate "pi-permissions.jsonc" cfg.permissions.config;
      })
    ]
  );
}
