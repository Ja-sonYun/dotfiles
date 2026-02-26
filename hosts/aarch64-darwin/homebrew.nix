{ lib, purpose, ... }:
let
  packageBrews =
    if purpose == "server" then
      [
        (import ../../infra/service/aarch64-darwin/homebrew.nix { inherit purpose; })
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
  ]
  ++ (
    if purpose == "main" then
      [
        "keith/formulae/reminders-cli"
      ]
    else
      [ ]
  );

  casks = [
    "ghostty"
    "aldente"
    "orbstack"
  ]
  ++ (
    if purpose == "main" then
      [
        "keycastr" # Show keystroke realtime
        "claude"
        "gimp"
        "sf-symbols"
        "discord"
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
        "raycast"

        "alfred"
        "aldente"
        "cleanshot"

        "hyprnote"
        "microsoft-remote-desktop"

        "protonvpn"

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
        "fastrepl/hyprnote"
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
    masApps =
      { }
      // (
        if purpose == "main" then
          { }
        else
          {
            Amphetamine = 937984704;
          }
      );
    onActivation = {
      # "zap" removes manually installed brews and casks
      cleanup = "zap";
      autoUpdate = false;
      upgrade = false;
    };
    brews = brews ++ allBrews;
    casks = casks ++ allCasks;
    taps = taps ++ allTaps;
  };
}
