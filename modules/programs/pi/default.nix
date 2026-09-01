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

    extensions = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Extension files/directories linked into ~/.pi/agent/extensions.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ wrappedPackage ];

    home.file = {
      "${agentDir}/settings.json".source = jsonFormat.generate "pi-settings.json" cfg.settings;
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
    // lib.mapAttrs' (
      name: source: lib.nameValuePair "${agentDir}/extensions/${name}" { inherit source; }
    ) cfg.extensions;
  };
}
