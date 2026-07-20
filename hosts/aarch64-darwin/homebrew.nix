{
  config,
  hasTag,
  lib,
  ...
}:
let
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
    if hasTag "gui" then
      [
        "displayplacer"
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
      "input-source-pro"
      "slack"
      "bambu-studio"
      "visual-studio-code"
      "discord"
      "keycastr"
      "gitify"
      "gimp"
      "bitwarden"
      "sf-symbols"
      "wallspace"
      "google-chrome"
      "drawio"
      "iina"
      "balenaetcher"
      "basictex"
      "openvpn-connect"
      "freecad"
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
