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

  selectSync =
    instanceName: resource:
    syncLib.select "programs.claude-code.instances.${instanceName}.sync.${resource}"
      cfg.instances.${instanceName}.sync.${resource};

  instanceResources = lib.mapAttrs (
    name: _:
    let
      mcpServers = lib.filterAttrs (
        serverName: _: !(builtins.elem serverName (cfg.settings.disabledMcpjsonServers or [ ]))
      ) (selectSync name "mcpServers" cfg.mcpServers);
    in
    {
      skills = selectSync name "skills" cfg.skills;
      agents = selectSync name "agents" (
        lib.genAttrs cfg.agentNames (agentName: "${cfg.agentsDir}/${agentName}.md")
      );
      inherit mcpServers;
      mcpPlugin = pkgs.runCommand "claude-code-${name}-mcp" { } ''
        install -Dm444 ${jsonFormat.generate "plugin.json" { name = cfg.mcpPluginName; }} \
          "$out/.claude-plugin/plugin.json"
        install -Dm444 ${jsonFormat.generate "mcp.json" { inherit mcpServers; }} \
          "$out/.mcp.json"
      '';
    }
  ) cfg.instances;

  nodeOnly = pkgs.runCommand "nodejs-24-node-only" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.nodejs_24}/bin/node $out/bin/node
  '';

  wrappedPackage = pkgs.symlinkJoin (
    {
      inherit (cfg.package) name;
      paths = [ cfg.package ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        rm "$out/bin/claude"
        makeWrapper ${cfg.package}/bin/claude "$out/bin/claude" \
          --prefix PATH : ${lib.makeBinPath ([ nodeOnly ] ++ cfg.extraPath)}
      '';
      meta = cfg.package.meta or { };
    }
    // lib.optionalAttrs (cfg.package ? version) { inherit (cfg.package) version; }
  );

  instancePackages = lib.mapAttrs (
    name: instance:
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      umask 077

      export CLAUDE_CONFIG_DIR=${lib.escapeShellArg "${config.home.homeDirectory}/${instance.home}"}
      ${pkgs.coreutils}/bin/mkdir -p "$CLAUDE_CONFIG_DIR"

      exec ${pkgs.state-get}/bin/state-run ${lib.escapeShellArg name} \
        ${wrappedPackage}/bin/claude ${
          lib.optionalString (instanceResources.${name}.mcpServers != { }) (
            lib.escapeShellArgs [
              "--plugin-dir"
              (toString instanceResources.${name}.mcpPlugin)
            ]
          )
        } "$@"
    ''
  ) cfg.instances;

  settingsFile = jsonFormat.generate "claude-code-settings.json" (
    cfg.settings
    // lib.optionalAttrs (cfg.customInstructions != "") {
      outputStyle = "Shared Instructions";
    }
    // {
      "$schema" = "https://json.schemastore.org/claude-code-settings.json";
    }
  );

  sharedFiles =
    home:
    {
      "${home}/settings.json".source = settingsFile;
    }
    // lib.optionalAttrs (cfg.context != null) {
      "${home}/CLAUDE.md".text = cfg.context;
    }
    // lib.optionalAttrs (cfg.customInstructions != "") {
      "${home}/output-styles/shared-instructions.md".text = ''
        ---
        name: Shared Instructions
        description: Shared personal working and response preferences
        keep-coding-instructions: true
        ---

        ${cfg.customInstructions}
      '';
    }
    // lib.optionalAttrs (cfg.keybindings != null) {
      "${home}/keybindings.json".text = builtins.toJSON cfg.keybindings;
    };
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
      description = "Claude Code package to install.";
    };

    finalPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages added to every Claude Code instance's PATH.";
    };

    defaultProfileName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      description = "Declared instance selected when ~/.state.toml is first created.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              home = lib.mkOption {
                type = lib.types.str;
                description = "Instance config directory relative to the user's home.";
              };

              sync = syncLib.mkOptions (name == cfg.defaultProfileName);
            };
          }
        )
      );
      default = { };
      description = "Claude Code commands with independent user profiles.";
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = "Claude Code JSON settings shared by every instance, including hooks and permissions.";
    };

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "CLAUDE.md content shared by every instance.";
    };

    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Instructions applied through a managed Claude Code output style.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Skill directory catalog selected by each instance's sync settings.";
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Directory of adapted Markdown agents selected by each instance's sync settings.";
    };

    agentNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Selectable agent names, matching Markdown file stems in agentsDir.";
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = { };
      description = ''
        MCP server catalog selected for each instance's managed hm plugin.
        Servers listed in settings.disabledMcpjsonServers are excluded from every instance.
      '';
    };

    mcpPluginName = lib.mkOption {
      type = lib.types.str;
      default = "hm";
      readOnly = true;
      internal = true;
    };

    chromeNativeHost.enable = lib.mkEnableOption "Claude Code Chrome native messaging host (Claude in Chrome)";

    keybindings = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      description = "Keybindings shared by every instance (written as JSON when non-null).";
    };

  };

  config = lib.mkMerge [
    { programs.claude-code.finalPackage = wrappedPackage; }

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
              description = "Claude Code Browser Extension Native Host";
              path = "${launcher}";
              type = "stdio";
              allowed_origins = [ "chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/" ];
            };
          };
      }
    ))

  ];
}
