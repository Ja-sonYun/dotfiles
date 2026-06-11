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
    pkgs.pi-retry.piExtensionPath
    pkgs.pi-mcp-adapter.piExtensionPath
    pkgs.context-mode.piExtensionPath
    pkgs.pi-lean-ctx.piExtensionPath
    pkgs.pi-chrome.piExtensionPath
    pkgs.rpiv-i18n.piExtensionPath
    pkgs.rpiv-args.piExtensionPath
    pkgs.rpiv-ask-user-question.piExtensionPath
    pkgs.rpiv-todo.piExtensionPath
    pkgs.rpiv-advisor.piExtensionPath
    pkgs.rpiv-web-tools.piExtensionPath
    pkgs.rpiv-btw.piExtensionPath
    pkgs.rpiv-pi.piExtensionPath
    pkgs.rpiv-pi.siblingExtensionPaths.rpivWorkflow
    pkgs.pi-markdown-preview.piExtensionPath
    pkgs.pi-simplify.piExtensionPath
    pkgs.piolium.piExtensionPath
    pkgs.pi-lens.piExtensionPath
  ];

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
        --prefix PATH : "${pkgs.lean-ctx}/bin" \
        --prefix NODE_OPTIONS " " "--no-warnings=ExperimentalWarning" \
        --set LEAN_CTX_BIN "${pkgs.lean-ctx}/bin/lean-ctx" \
        --set PI_SKIP_VERSION_CHECK 1 \
        --run ${lib.escapeShellArg blockedPackageCommandCheck} \
        ${extensionFlags}
    '';
  };

  piKeybindings = {
    "tui.input.newLine" = [ "alt+enter" ];
  };
in
{
  home.packages = [
    piWithExtensions
  ];

  home.file.".pi/agent/AGENTS.md" = {
    force = true;
    text = piAgentsMd;
  };

  home.file.".pi/agent/settings.json" = {
    force = true;
    text = builtins.toJSON piSettings;
  };

  home.file.".pi/agent/keybindings.json" = {
    force = true;
    text = builtins.toJSON piKeybindings;
  };
}
