{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code;
  syncLib = import ../ai-agents/sync.nix { inherit lib; };
  jsonFormat = pkgs.formats.json { };
  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];

  settings = import ./settings.nix { inherit config lib pkgs; };
  instances = import ./instances.nix { inherit config lib pkgs; };
  inherit (settings) settingsFile sharedFiles;
  inherit (instances) instanceResources wrappedPackage instancePackages;
in
{
  imports = [
    ../state
    ./status-line
  ];

  disabledModules = [ "programs/claude-code" ];

  options.programs.claude-code = {
    enable = lib.mkEnableOption "Claude Code";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      description = "Claude Code package.";
    };

    finalPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages on each instance's PATH.";
    };

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
                description = "Home-relative instance config directory.";
              };

              sync = syncLib.mkOptions (name == cfg.defaultProfileName);
            };
          }
        )
      );
      default = { };
      description = "Claude Code instances.";
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = "Shared Claude Code settings.";
    };

    settingsTransform = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Build-time settings transformer (JSON stdin/stdout).";
    };

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Shared CLAUDE.md content.";
    };

    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Output style instructions.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Available skill directories.";
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Markdown agent directory.";
    };

    agentNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Available agent names.";
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = { };
      description = "Available MCP servers.";
    };

    mcpPluginName = lib.mkOption {
      type = lib.types.str;
      default = "hm";
      readOnly = true;
      internal = true;
    };

    chromeNativeHost.enable = lib.mkEnableOption "Claude in Chrome";

    keybindings = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      description = "Shared keybindings.";
    };

  };

  config = lib.mkMerge [
    {
      programs.claude-code.finalPackage = wrappedPackage;

      # Let Home Manager remove its settings symlink before writing a regular file.
      home.activation.claudeSettingsMerge = lib.hm.dag.entryAfter [ "linkGeneration" ] (
        let
          homes =
            if cfg.instances == { } then
              [ ".claude" ]
            else
              lib.unique (lib.mapAttrsToList (_: instance: instance.home) cfg.instances);
          fragment = if cfg.enable then settingsFile else jsonFormat.generate "claude-code-settings.json" { };
        in
        lib.concatMapStringsSep "\n" (
          home:
          let
            instanceHome = "${config.home.homeDirectory}/${home}";
            target = "${instanceHome}/settings.json";
          in
          ''
            ${lib.optionalString cfg.enable ''
              run ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg instanceHome}
            ''}
            if ${
              if cfg.enable then "true" else "false"
            } || [[ -f ${lib.escapeShellArg target} && -f ${lib.escapeShellArg "${target}.nix-managed.json"} ]]; then
              run ${pkgs.python3}/bin/python3 ${./merge-settings-json.py} \
                ${lib.escapeShellArg target} ${fragment}
            fi
          ''
        ) homes
      );
    }

    (lib.mkIf cfg.enable {
      programs.state.commands.claude = lib.mkIf (cfg.instances != { }) {
        key = "defaults.claude";
        default = cfg.defaultProfileName;
        choices = lib.mapAttrs (name: package: "${package}/bin/${name}") instancePackages;
      };

      home.packages =
        if cfg.instances == { } then [ wrappedPackage ] else lib.attrValues instancePackages;

      assertions = [
        {
          assertion = cfg.instances == { } || builtins.hasAttr cfg.defaultProfileName cfg.instances;
          message = "programs.claude-code.defaultProfileName must name a declared instance.";
        }
        {
          assertion = !(builtins.hasAttr "claude" cfg.instances);
          message = "programs.claude-code.instances must not use the reserved command name claude.";
        }
        {
          assertion = cfg.agentNames == [ ] || cfg.agentsDir != null;
          message = "programs.claude-code.agentNames requires agentsDir.";
        }
      ];

      home.file =
        if cfg.instances == { } then
          sharedFiles ".claude"
          // lib.optionalAttrs (cfg.agentsDir != null) {
            ".claude/agents".source = cfg.agentsDir;
          }
        else
          lib.concatMapAttrs (
            instanceName: instance:
            sharedFiles instance.home
            // lib.mapAttrs' (
              name: source: lib.nameValuePair "${instance.home}/skills/${name}" { inherit source; }
            ) instanceResources.${instanceName}.skills
            // lib.optionalAttrs (instanceResources.${instanceName}.agents != { }) {
              "${instance.home}/agents".source = pkgs.linkFarm "claude-${instanceName}-agents" (
                lib.mapAttrsToList (name: path: {
                  name = "${name}.md";
                  inherit path;
                }) instanceResources.${instanceName}.agents
              );
            }
          ) cfg.instances;
    })

    (lib.mkIf (cfg.enable && cfg.chromeNativeHost.enable && pkgs.stdenv.hostPlatform.isDarwin) (
      let
        launcher = pkgs.writeShellScript "claude-chrome-native-host" ''
          exec ${wrappedPackage}/bin/claude --chrome-native-host "$@"
        '';
      in
      {
        home.file."Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json" =
          {
            force = true;
            text = builtins.toJSON {
              name = "com.anthropic.claude_code_browser_extension";
              description = "Claude in Chrome native host";
              path = "${launcher}";
              type = "stdio";
              allowed_origins = [ "chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/" ];
            };
          };
      }
    ))

  ];
}
