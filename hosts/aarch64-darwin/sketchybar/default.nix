{ pkgs, ... }:
let
  sketchybarHelper = pkgs.stdenv.mkDerivation {
    name = "sketchybar-helper";
    src = ./helper;
    nativeBuildInputs = [ pkgs.gnumake ];
    buildPhase = "make";
    installPhase = ''
      mkdir -p $out/bin
      cp helper $out/bin/
    '';
  };
  sketchybarConfig = pkgs.stdenvNoCC.mkDerivation {
    name = "sketchybar-config";
    src = ./.;
    nativeBuildInputs = [
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R config $out/config
      cp sketchybarrc $out/sketchybarrc
      chmod -R u+w $out
      find "$out" -type f -print | while IFS= read -r file; do
        if head -n 1 "$file" | grep -qE '^#!.*zsh'; then
          sed -i "1s|^#!.*|#!${pkgs.zsh}/bin/zsh -f|" "$file"
        fi
      done
      runHook postInstall
    '';
  };
  pathBin = pkgs.lib.makeBinPath [
    pkgs.gh
    pkgs.jq
    pkgs.gawk
    pkgs.sketchybar
    pkgs.flock
    pkgs.yabai
    pkgs.taskwarrior3
    pkgs.icalPal
  ];
in
{
  home.packages = [
    pkgs.sketchybar
  ];

  launchd.agents.sketchybar = {
    enable = true;
    config = {
      Label = "com.user.sketchybar";
      ProgramArguments = [
        "${pkgs.sketchybar}/bin/sketchybar"
        "-c"
        "${sketchybarConfig}/sketchybarrc"
      ];
      EnvironmentVariables = {
        PATH = "${pathBin}:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        SKETCHYBAR_CONFIG_DIR = "${sketchybarConfig}/config";
        SKETCHYBAR_HELPER_BIN = "${sketchybarHelper}/bin/helper";
      };
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/tmp/sketchybar.out.log";
      StandardErrorPath = "/tmp/sketchybar.err.log";
    };
  };
}
