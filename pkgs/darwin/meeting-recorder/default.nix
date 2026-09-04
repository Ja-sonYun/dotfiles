{
  apple-sdk_15,
  lib,
  stdenv,
  writeText,
}:
let
  infoPlist = writeText "meeting-recorder-Info.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key>
      <string>meeting-recorder</string>
      <key>CFBundleIdentifier</key>
      <string>com.jaykuroyanagi.meeting-recorder</string>
      <key>CFBundleName</key>
      <string>Meeting Recorder</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
      <key>CFBundleShortVersionString</key>
      <string>0.1.0</string>
      <key>CFBundleVersion</key>
      <string>1</string>
      <key>LSUIElement</key>
      <true/>
      <key>NSMicrophoneUsageDescription</key>
      <string>Record microphone audio during detected meetings.</string>
      <key>NSAudioCaptureUsageDescription</key>
      <string>Record system audio during detected meetings.</string>
      <key>NSScreenCaptureUsageDescription</key>
      <string>Capture system audio during detected meetings.</string>
    </dict>
    </plist>
  '';
in
stdenv.mkDerivation {
  pname = "meeting-recorder";
  version = "0.1.0";

  src = ./.;

  strictDeps = true;
  dontConfigure = true;

  buildInputs = [ apple-sdk_15 ];

  buildPhase = ''
    runHook preBuild

    $CC \
      -fobjc-arc \
      -mmacosx-version-min=15.0 \
      -O2 \
      -framework AudioToolbox \
      -framework AVFoundation \
      -framework CoreMedia \
      -framework Foundation \
      -framework ScreenCaptureKit \
      main.m \
      -o meeting-recorder

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    app="$out/Applications/Meeting Recorder.app"
    mkdir -p "$app/Contents/MacOS" "$out/bin"
    install -m755 meeting-recorder "$app/Contents/MacOS/meeting-recorder"
    cp ${infoPlist} "$app/Contents/Info.plist"
    ln -s "$app/Contents/MacOS/meeting-recorder" "$out/bin/meeting-recorder"

    runHook postInstall
  '';

  meta = {
    description = "Record macOS system and microphone audio for meetings";
    platforms = lib.platforms.darwin;
    mainProgram = "meeting-recorder";
  };
}
