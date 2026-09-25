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

  configDir = ".pi/agent";

  basePackage =
    if cfg.extraPath == [ ] then cfg.package else cfg.package.override { inherit (cfg) extraPath; };

  # Read secrets at launch to avoid baking them into the store.
  wrappedPackage =
    if cfg.env == { } then
      basePackage
    else
      pkgs.runCommand "${basePackage.name}-wrapped" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
        mkdir -p $out/bin
        makeWrapper ${basePackage}/bin/pi $out/bin/pi \
          --run ${lib.escapeShellArg (pkgs.tool.shell.util.shellExports cfg.env)}
      '';
in
{
  imports = [
    ./extensions/hooks.nix
    ./extensions/mcp.nix
    ./extensions/providers.nix
  ];

  options.programs.pi = {
    enable = lib.mkEnableOption "Pi coding agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pi;
      description = "Pi package.";
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages added to Pi's PATH.";
    };

    env = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          pkgs.tool.secretValue.type
        ]
      );
      default = { };
      example = {
        CAPI_KEY._secret = "/run/agenix/capi-key";
      };
      description = "Environment variables; supports { _secret = path; }.";
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = "Pi settings.";
    };

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "AGENTS.md content.";
    };

    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional system instructions.";
    };

    systemPrompt = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "System prompt.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Skill directories.";
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Subagent directory.";
    };

    extensions = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Extension files and directories.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ wrappedPackage ];

    home.file = {
      "${configDir}/settings.json".source = jsonFormat.generate "pi-settings.json" cfg.settings;
    }
    // lib.optionalAttrs (cfg.context != null) {
      "${configDir}/AGENTS.md".text = cfg.context;
    }
    // lib.optionalAttrs (cfg.customInstructions != "") {
      "${configDir}/APPEND_SYSTEM.md".text = cfg.customInstructions;
    }
    // lib.optionalAttrs (cfg.systemPrompt != null) {
      "${configDir}/SYSTEM.md".text = cfg.systemPrompt;
    }
    // lib.mapAttrs' (
      name: source: lib.nameValuePair "${configDir}/skills/${name}" { inherit source; }
    ) cfg.skills
    // lib.optionalAttrs (cfg.agentsDir != null) {
      "${configDir}/agents".source = cfg.agentsDir;
    }
    // lib.mapAttrs' (
      name: source: lib.nameValuePair "${configDir}/extensions/${name}" { inherit source; }
    ) cfg.extensions;
  };
}
