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
  configDirs = [ configDir ] ++ lib.optional (cfg.dev.extensionsSource != null) ".pi/agent-dev";

  nativeSettings =
    agentDir:
    removeAttrs cfg.settings [ "extensions" ]
    // {
      extensions = map (
        extension:
        if agentDir == ".pi/agent-dev" && extension ? devSource then
          extension.devSource
        else
          extension.source
      ) (lib.filter (extension: extension.enable) (lib.attrValues cfg.settings.extensions));
    };

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
        ln -s ${basePackage}/bin/pi-dev $out/bin/pi-dev
      '';
in
{
  imports = [
    ./mcp.nix
    ./extensions/providers.nix
    ./extensions/subagent.nix
    ./extensions/permissions.nix
    ./extensions/redact.nix
    ./extensions/message-lines.nix
    ./extensions/tool-summaries.nix
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
      type = lib.types.submodule {
        freeformType = jsonFormat.type;
      };
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

    extensions = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Extension files and directories.";
    };

    dev.extensionsSource = lib.mkOption {
      type = lib.types.nullOr sourceType;
      default = null;
      description = "Extension directory for the separate pi-dev profile.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ wrappedPackage ];

    home.file = lib.mkMerge (
      map (
        agentDir:
        {
          "${agentDir}/settings.json".source = jsonFormat.generate "pi-settings.json" (
            nativeSettings agentDir
          );
        }
        // lib.optionalAttrs (cfg.context != null) {
          "${agentDir}/AGENTS.md".text = cfg.context;
        }
        // lib.optionalAttrs (cfg.customInstructions != "") {
          "${agentDir}/APPEND_SYSTEM.md".text = cfg.customInstructions;
        }
        // lib.optionalAttrs (cfg.systemPrompt != null) {
          "${agentDir}/SYSTEM.md".text = cfg.systemPrompt;
        }
        // lib.mapAttrs' (
          name: source: lib.nameValuePair "${agentDir}/skills/${name}" { inherit source; }
        ) cfg.skills
      ) configDirs
      ++ [
        (lib.mapAttrs' (
          name: source: lib.nameValuePair "${configDir}/extensions/${name}" { inherit source; }
        ) cfg.extensions)
        (lib.optionalAttrs (cfg.dev.extensionsSource != null) {
          ".pi/agent-dev/extensions".source = cfg.dev.extensionsSource;
        })
      ]
    );
  };
}
