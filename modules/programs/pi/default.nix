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
    if cfg.envFiles == { } then
      basePackage
    else
      pkgs.runCommand "${basePackage.name}-wrapped" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
        mkdir -p $out/bin
        makeWrapper ${basePackage}/bin/pi $out/bin/pi \
          ${lib.concatStringsSep " \\\n      " (
            lib.mapAttrsToList (
              name: file: "--run ${lib.escapeShellArg ''export ${name}="$(cat ${file} 2>/dev/null)"''}"
            ) cfg.envFiles
          )}
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
      description = "Pi coding agent package to install.";
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages added to Pi's PATH.";
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

    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Content appended through ~/.pi/agent/APPEND_SYSTEM.md.";
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

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Directory containing adapted Pi subagents.";
    };

    extensions = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Extension files/directories linked into ~/.pi/agent/extensions.";
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
