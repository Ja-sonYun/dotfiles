{ cacheDir
, pkgs
, config
, ...
}:
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
in
{
  launchd.user.agents.sketchybar = {
    path = with pkgs; [
      gh
      jq
      gawk
      sketchybar
      config.environment.systemPath
      flock
      yabai
      taskwarrior3
      icalPal
    ];

    environment = {
      SKETCHYBAR_CONFIG_DIR = "${sketchybarConfig}/config";
      SKETCHYBAR_HELPER_BIN = "${sketchybarHelper}/bin/helper";
    };

    serviceConfig = {
      ProgramArguments = [
        "${pkgs.sketchybar}/bin/sketchybar"
        "-c"
        "${sketchybarConfig}/sketchybarrc"
      ];

      KeepAlive = true;
      RunAtLoad = true;

      StandardOutPath = "${cacheDir}/logs/sketchybar.out.log";
      StandardErrorPath = "${cacheDir}/logs/sketchybar.err.log";
    };
  };
}
