{
  config,
  lib,
  purpose,
  hostname,
  ...
}:
let
  packageBrews =
    if hostname == "Jays-MacBook-Pro-Server" then
      [
        (import ../../infra/services/Jays-MacBook-Pro-Server/homebrew.nix { inherit purpose; })
      ]
    else
      [ ];

  allBrews = lib.concatMap (pkg: pkg.homebrew.brews or [ ]) packageBrews;
  allCasks = lib.concatMap (pkg: pkg.homebrew.casks or [ ]) packageBrews;
  allTaps = lib.concatMap (pkg: pkg.homebrew.taps or [ ]) packageBrews;

  # Keep selected Homebrew formulae installed for dependencies, but unlinked from
  # the Homebrew prefix bin directory so their commands are not exposed on PATH.
  unlinkedBrews = [
    "node"
  ];
  unlinkedBrewArgs = builtins.concatStringsSep " " (map lib.escapeShellArg unlinkedBrews);
  brewBin = "${config.homebrew.prefix}/bin/brew";
  brewUser = config.homebrew.user;

  brews = [
    "qemu"
    "tccutil"
    "localstack/tap/localstack-cli"
    "bitwarden-cli"
    "mole"
    "ollama"
    "container"
    "diskonaut"
  ]
  ++ (
    if purpose == "main" then
      [
        "displayplacer"
        "keith/formulae/reminders-cli"
      ]
    else
      [ ]
  );

  casks = [
    "ghostty"
    "orbstack"
    "obsidian"
    "codex-app"
    "appcleaner"
    "input-source-pro"
  ]
  ++ (
    if purpose == "main" then
      [
        "keycastr" # Show keystroke realtime
        "claude"
        "gimp"
        "bitwarden"
        "sf-symbols"
        "discord"
        "wallspace"
        "google-chrome"
        "slack"
        "appcleaner"
        "drawio"
        "iina"
        "chatgpt"
        "chatgpt-atlas"
        "ultimaker-cura"
        "balenaetcher"
        "basictex"
        "openvpn-connect"
        "freecad"
        "blender"
        "visual-studio-code"
        "obs"
        "pdf-expert"
        "jump-desktop"
        "parallels"
        "kicad"
        "firefox"
        "notion"
        "devonthink"
        "alcove"
        "cleanshot"
        "microsoft-remote-desktop"
        "protonvpn"
        "bambu-studio"

        # TODO: Move to nix
        "macfuse"
      ]
    else
      [
      ]
  );

  taps = [
    "localstack/tap"
  ]
  ++ (
    if purpose == "main" then
      [
        "keith/formulae"
      ]
    else
      [ ]
  );
in
{
  homebrew = {
    enable = true;
    global = {
      autoUpdate = false;
    };
    # will not be uninstalled when removed
    masApps = { } // (if purpose == "main" then { } else { });
    onActivation = {
      # "zap" removes manually installed brews and casks
      cleanup = "none";
      autoUpdate = false;
      upgrade = true;
    };
    brews = brews ++ allBrews;
    casks = casks ++ allCasks;
    taps = taps ++ allTaps;
  };

  system.activationScripts.postActivation.text = lib.mkIf (unlinkedBrews != [ ]) (
    lib.mkAfter ''
      brew=${lib.escapeShellArg brewBin}
      if [ -x "$brew" ]; then
        unlinked_formulae=(${unlinkedBrewArgs})
        for formula in "''${unlinked_formulae[@]}"; do
          if /usr/bin/sudo --user=${lib.escapeShellArg brewUser} --set-home \
            env HOMEBREW_NO_AUTO_UPDATE=1 "$brew" list --formula "$formula" >/dev/null 2>&1; then
            echo "unlinking Homebrew formula from PATH: $formula"
            /usr/bin/sudo --user=${lib.escapeShellArg brewUser} --set-home \
              env HOMEBREW_NO_AUTO_UPDATE=1 "$brew" unlink "$formula" >/dev/null 2>&1 || true
          fi
        done
      fi
    ''
  );
}
