{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code;
  jsonFormat = pkgs.formats.json { };

  sourceType =
    with lib.types;
    oneOf [
      package
      path
      str
    ];

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

  settingsFile = jsonFormat.generate "claude-code-settings.json" (
    cfg.settings
    // lib.optionalAttrs (cfg.customInstructions != "") {
      outputStyle = "Shared Instructions";
    }
    // {
      "$schema" = "https://json.schemastore.org/claude-code-settings.json";
    }
  );

  mcpPlugin = pkgs.runCommand "claude-code-home-manager" { } ''
    install -Dm444 ${jsonFormat.generate "plugin.json" { name = "hm"; }} \
      "$out/.claude-plugin/plugin.json"
    install -Dm444 ${jsonFormat.generate "mcp.json" { inherit (cfg) mcpServers; }} \
      "$out/.mcp.json"
  '';
in
{
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
      description = "Packages added to Claude Code's PATH.";
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = "Claude Code JSON settings.";
    };

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Content for ~/.claude/CLAUDE.md.";
    };

    customInstructions = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Instructions applied through a managed Claude Code output style.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf sourceType;
      default = { };
      description = "Skill directories linked into ~/.claude/skills.";
    };

    agentsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Directory linked into ~/.claude/agents.";
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = { };
      description = "MCP servers exposed through the managed hm plugin.";
    };

    chromeNativeHost.enable = lib.mkEnableOption "Claude Code Chrome native messaging host (Claude in Chrome)";

    keybindings = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      description = "Contents of ~/.claude/keybindings.json (written as JSON when non-null).";
    };

    desktopConfig = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      description = "Contents of ~/Library/Application Support/Claude/claude_desktop_config.json (written as JSON when non-null).";
    };
  };

  config = lib.mkMerge [
    { programs.claude-code.finalPackage = wrappedPackage; }

    (lib.mkIf cfg.enable {
      home.packages = [ wrappedPackage ];

      home.file = {
        ".claude/settings.json".source = settingsFile;
      }
      // lib.optionalAttrs (cfg.context != null) {
        ".claude/CLAUDE.md".text = cfg.context;
      }
      // lib.optionalAttrs (cfg.customInstructions != "") {
        ".claude/output-styles/shared-instructions.md".text = ''
          ---
          name: Shared Instructions
          description: Shared personal working and response preferences
          keep-coding-instructions: true
          ---

          ${cfg.customInstructions}
        '';
      }
      // lib.mapAttrs' (
        name: source: lib.nameValuePair ".claude/skills/${name}" { inherit source; }
      ) cfg.skills
      // lib.optionalAttrs (cfg.agentsDir != null) {
        ".claude/agents".source = cfg.agentsDir;
      }
      // lib.optionalAttrs (cfg.mcpServers != { }) {
        ".claude/skills/claude-code-home-manager".source = mcpPlugin;
      };
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

    (lib.mkIf (cfg.enable && cfg.keybindings != null) {
      home.file.".claude/keybindings.json".text = builtins.toJSON cfg.keybindings;
    })

    (lib.mkIf (cfg.enable && cfg.desktopConfig != null) {
      home.file."Library/Application Support/Claude/claude_desktop_config.json" = {
        force = true;
        text = builtins.toJSON cfg.desktopConfig;
      };
    })
  ];
}
