{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.codex;
  syncLib = import ../ai-agents/sync.nix { inherit lib; };
  tomlFormat = pkgs.formats.toml { };
  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];

  settings = import ./settings.nix { inherit config lib pkgs; };
  instances = import ./instances.nix {
    inherit
      config
      lib
      pkgs
      settings
      ;
  };
  inherit (settings)
    codexConfigFile
    managedFragment
    configMerge
    settingsSecrets
    flagSecrets
    sharedFiles
    ;
  inherit (instances)
    instanceResources
    wrappedPackage
    instancePackages
    independentInstances
    ;
in
{
  imports = [ ../state ];

  disabledModules = [ "programs/codex" ];

  options.programs.codex = {
    enable = lib.mkEnableOption "Codex";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.codex;
      description = "Codex package.";
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages on each instance's PATH.";
    };

    trustCurrentDirectory = lib.mkEnableOption "trusting the current directory when starting Codex";

    defaultProfileName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      description = "Initial default instance.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              home = lib.mkOption {
                type = lib.types.str;
                description = "Home-relative instance directory.";
              };

              shareWith = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Home-relative Codex directory to share, except authentication.";
              };

              sync = syncLib.mkOptions (name == cfg.defaultProfileName);
            };
          }
        )
      );
      default = { };
      description = "Codex instances.";
    };

    settings = lib.mkOption {
      inherit (tomlFormat) type;
      default = { };
      description = "Shared Codex settings.";
    };

    settingsTransform = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Build-time settings transformer (JSON stdin/stdout).";
    };

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Shared AGENTS.md content.";
    };

    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional developer instructions.";
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Custom agent directory.";
    };

    agentNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Available agent names.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Available skill directories.";
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = "Shared rule file contents.";
    };

    rulesSources = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "Shared rule file sources; names must differ from rules.";
    };
  };

  config = lib.mkMerge [
    {
      home.activation.codexConfigMerge = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        if cfg.instances == { } then
          ''
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
          ''
        else
          lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: instance:
              let
                instanceHome = "${config.home.homeDirectory}/${instance.home}";
              in
              ''
                ${lib.optionalString cfg.enable ''
                  run ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg instanceHome}
                ''}
                if ${
                  if cfg.enable then "true" else "false"
                } || [[ -f ${lib.escapeShellArg "${instanceHome}/config.toml"} ]]; then
                  run ${configMerge}/bin/merge-codex-config \
                    ${lib.escapeShellArg "${instanceHome}/config.toml"} ${instanceResources.${name}.fragment}
                fi
              ''
            ) independentInstances
          )
      );
    }
    (lib.mkIf cfg.enable {
      programs.state.commands.codex = lib.mkIf (cfg.instances != { }) {
        key = "defaults.codex";
        default = cfg.defaultProfileName;
        choices = lib.mapAttrs (name: package: "${package}/bin/${name}") instancePackages;
      };

      home.packages =
        if cfg.instances == { } then [ wrappedPackage ] else lib.attrValues instancePackages;

      assertions = [
        {
          assertion =
            lib.intersectLists (builtins.attrNames cfg.rules) (builtins.attrNames cfg.rulesSources) == [ ];
          message = "programs.codex.rules and rulesSources must use distinct names.";
        }
        {
          assertion = cfg.instances == { } || builtins.hasAttr cfg.defaultProfileName cfg.instances;
          message = "programs.codex.defaultProfileName must name a declared instance.";
        }
        {
          assertion = !(builtins.hasAttr "codex" cfg.instances);
          message = "programs.codex.instances must not use the reserved command name codex.";
        }
        {
          assertion = cfg.agentNames == [ ] || cfg.agentsDir != null;
          message = "programs.codex.agentNames requires agentsDir.";
        }
        {
          assertion = settingsSecrets.invalidSecretPaths == [ ];
          message = "programs.codex.settings contains invalid _secret values at: ${lib.concatStringsSep ", " settingsSecrets.invalidSecretPaths}.";
        }
        {
          assertion = flagSecrets.secretPaths == [ ];
          message = "programs.codex.settings only supports _secret in settings merged into instance config.toml files.";
        }
      ];

      home.file =
        if cfg.instances == { } then
          sharedFiles ".codex"
          // lib.mapAttrs' (
            name: source: lib.nameValuePair ".codex/skills/${name}" { inherit source; }
          ) cfg.skills
        else
          lib.concatMapAttrs (
            instanceName: instance:
            sharedFiles instance.home
            // lib.mapAttrs' (
              name: source: lib.nameValuePair "${instance.home}/skills/${name}" { inherit source; }
            ) instanceResources.${instanceName}.skills
          ) independentInstances;
    })
  ];
}
