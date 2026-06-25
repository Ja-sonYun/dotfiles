{
  pkgs,
  lib,
  agenix-secrets,
  ...
}:
let
  aiBundle = import "${agenix-secrets}/ai-bundle.nix" { inherit pkgs; };
  piVersion = lib.getVersion pkgs.pi;
  piAgentsMd = (lib.trim (builtins.readFile aiBundle.agentsMdSrc)) + "\n";

  piExtensions = [
    pkgs.pi-subagents.piExtensionPath
    pkgs.pi-mcp-adapter.piExtensionPath
    pkgs.piolium.piExtensionPath
    pkgs.ponytail.piExtensionPath
  ];

  piLocalExtensionEntries = lib.filterAttrs (
    name: type:
    (type == "regular" && (lib.hasSuffix ".ts" name || lib.hasSuffix ".json" name))
    || type == "directory"
  ) (builtins.readDir ./extensions);

  piLocalExtensionHomeFiles = lib.mapAttrs' (
    name: _type:
    lib.nameValuePair ".pi/agent/extensions/${name}" {
      force = true;
      source = ./extensions + "/${name}";
    }
  ) piLocalExtensionEntries;

  extensionFlags = lib.concatMapStringsSep " \\\n        " (
    extension: ''--add-flags "-e" --add-flags "${extension}"''
  ) piExtensions;

  blockedPackageCommandCheck = ''
    case "''${1-}" in
      install|remove|uninstall|update)
        printf '%s\n' "pi ''${1} is disabled in this Nix-managed wrapper. Manage Pi packages through dotfiles/Nix instead." >&2
        exit 64
      ;;
    esac
  '';

  piSettings = {
    defaultProvider = "openai-codex";
    defaultModel = "gpt-5.5";
    defaultThinkingLevel = "xhigh";
    theme = "dark";
    quietStartup = true;
    defaultProjectTrust = "always";
    lastChangelogVersion = piVersion;
    enableAnalytics = false;
    enableInstallTelemetry = false;
    packages = [ ];
    skills = [
      "${aiBundle.skillsSrc}"
    ];
    enableSkillCommands = true;
    retry = {
      provider = {
        maxRetries = 0;
        maxRetryDelayMs = 60000;
      };
    };
  };

  piWithExtensions = pkgs.symlinkJoin {
    name = "pi-with-extensions-${piVersion}";
    paths = [ pkgs.pi ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      mv $out/bin/pi $out/bin/pi-real
      makeWrapper $out/bin/pi-real $out/bin/pi \
        --prefix NODE_OPTIONS " " "--no-warnings=ExperimentalWarning" \
        --set PI_SKIP_VERSION_CHECK 1 \
        --run ${lib.escapeShellArg blockedPackageCommandCheck} \
        ${extensionFlags}
    '';
  };

  piKeybindings = {
    "tui.input.newLine" = [ "shift+enter" ];
    "tui.input.submit" = [ "enter" ];
    "tui.editor.deleteToLineStart" = [ "alt+backspace" ];
    "tui.editor.deleteWordBackward" = [ "ctrl+w" ];
    "tui.editor.deleteCharForward" = [ "delete" ];
    "tui.editor.deleteToLineEnd" = [ "ctrl+delete" ];
  };
in
{
  home.packages = [
    piWithExtensions
  ];

  home.file = piLocalExtensionHomeFiles // {
    ".pi/agent/AGENTS.md" = {
      force = true;
      text = piAgentsMd;
    };

    ".pi/agent/agents" = {
      force = true;
      source = aiBundle.agentsSrc;
    };

    ".pi/agent/settings.json" = {
      force = true;
      text = builtins.toJSON piSettings;
    };

    ".pi/agent/keybindings.json" = {
      force = true;
      text = builtins.toJSON piKeybindings;
    };
  };
}
