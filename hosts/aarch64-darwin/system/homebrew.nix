{
  hasTag,
  lib,
  ...
}:
let
  brews = [
    "qemu"
    "tccutil"
    "bitwarden-cli"
    "mole"
    "ollama"
    "container"
    "diskonaut"
  ]
  ++ (
    if hasTag "gui" then
      [
        "keith/formulae/reminders-cli"
      ]
    else
      [ ]
  );

  casks =
    lib.optionals (hasTag "gui") [
      "ghostty"
      "orbstack"
      "obsidian"
      "appcleaner"
      "slack"
      "bambu-studio"
      "visual-studio-code"
      "discord"
      "keycastr"
      "gimp"
      "bitwarden"
      "sf-symbols"
      "wallspace"
      "stats"
      "google-chrome"
      "drawio"
      "iina"
      "balenaetcher"
      "basictex"
      "openvpn-connect"
      "freecad"
      "openscad@snapshot"
      "blender"
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
      "autodesk-fusion"
      "macfuse"
    ]
    ++ lib.optionals (hasTag "gui" && hasTag "ai") [
      "chatgpt"
      "claude"
    ];

  taps = [
    "localstack/tap"
  ]
  ++ (
    if hasTag "gui" then
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
    # Keep dependency-only Node binaries off PATH.
    formulaLinks.node = false;
    global = {
      autoUpdate = false;
    };
    masApps = { };
    onActivation = {
      cleanup = "uninstall";
      autoUpdate = true;
      upgrade = true;
    };
    inherit brews casks taps;
  };

}
