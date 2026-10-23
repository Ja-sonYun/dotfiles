{
  apple-sdk_15,
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "slack-launcher";
  version = "1.0";
  src = ./.;
  buildInputs = [ apple-sdk_15 ];

  buildPhase = ''
    runHook preBuild
    $CC -fobjc-arc -fblocks -framework Cocoa -framework CoreServices main.m -o slack-launcher
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    app="$out/Applications/Slack.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    install -m755 slack-launcher "$app/Contents/MacOS/slack-launcher"
    cp Info.plist "$app/Contents/Info.plist"
    runHook postInstall
  '';

  meta = {
    description = "Slack launcher with local debugging and URL forwarding";
    platforms = lib.platforms.darwin;
  };
}
