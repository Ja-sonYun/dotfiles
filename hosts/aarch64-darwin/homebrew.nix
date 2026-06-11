{ lib, purpose, hostname, ... }:
let
  packageBrews =
    if hostname == "Jays-MacBook-Pro-Server" then
      [
        (import ../../infra/service/Jays-MacBook-Pro-Server/homebrew.nix { inherit purpose; })
      ]
    else
      [ ];

  allBrews = lib.concatMap (pkg: pkg.homebrew.brews or [ ]) packageBrews;
  allCasks = lib.concatMap (pkg: pkg.homebrew.casks or [ ]) packageBrews;
  allTaps = lib.concatMap (pkg: pkg.homebrew.taps or [ ]) packageBrews;

  brews = [
    "qemu"
    "tccutil"
    "localstack/tap/localstack-cli"
    "bitwarden-cli"
    "mole"
    "ollama"
    "container"
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
}
