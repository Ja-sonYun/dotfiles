{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code;
  nodeOnly = pkgs.runCommand "nodejs-24-node-only" { } ''
    mkdir -p $out/bin
    ln -s ${pkgs.nodejs_24}/bin/node $out/bin/node
  '';
  wrapClaudePackage =
    package:
    if package == null then
      null
    else
      pkgs.symlinkJoin (
        {
          inherit (package) name;
          paths = [ package ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            rm "$out/bin/claude"
            makeWrapper ${package}/bin/claude "$out/bin/claude" \
              --prefix PATH : ${lib.makeBinPath ([ nodeOnly ] ++ cfg.extraPath)}
          '';
          meta = package.meta or { };
        }
        // lib.optionalAttrs (package ? version) { inherit (package) version; }
      );
in
{
  options.programs.claude-code = {
    package = lib.mkOption {
      apply = wrapClaudePackage;
    };

    extraPath = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages added to Claude Code's PATH.";
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
    (lib.mkIf (cfg.chromeNativeHost.enable && pkgs.stdenv.hostPlatform.isDarwin) (
      let
        launcher = pkgs.writeShellScript "claude-chrome-native-host" ''
          exec ${cfg.package}/bin/claude --chrome-native-host "$@"
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

    (lib.mkIf (cfg.keybindings != null) {
      home.file.".claude/keybindings.json".text = builtins.toJSON cfg.keybindings;
    })

    (lib.mkIf (cfg.desktopConfig != null) {
      home.file."Library/Application Support/Claude/claude_desktop_config.json" = {
        force = true;
        text = builtins.toJSON cfg.desktopConfig;
      };
    })
  ];
}
