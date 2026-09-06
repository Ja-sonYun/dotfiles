{
  apple-sdk_15,
  lib,
  stdenv,
  writeText,
}:
let
  infoPlist = writeText "calendar-event-query-Info.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key>
      <string>calendar-event-query</string>
      <key>CFBundleIdentifier</key>
      <string>com.jaykuroyanagi.calendar-event-query</string>
      <key>CFBundleName</key>
      <string>Calendar Event Query</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
      <key>CFBundleShortVersionString</key>
      <string>0.1.0</string>
      <key>CFBundleVersion</key>
      <string>1</string>
      <key>LSUIElement</key>
      <true/>
      <key>NSCalendarsFullAccessUsageDescription</key>
      <string>Find the current meeting title for meeting recordings.</string>
    </dict>
    </plist>
  '';
in
stdenv.mkDerivation {
  pname = "calendar-event-query";
  version = "0.1.0";

  src = ./.;

  strictDeps = true;
  dontConfigure = true;

  buildInputs = [ apple-sdk_15 ];

  buildPhase = ''
    runHook preBuild

    $CC \
      -fobjc-arc \
      -mmacosx-version-min=14.0 \
      -O2 \
      -framework EventKit \
      -framework Foundation \
      main.m \
      -o calendar-event-query

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    app="$out/Applications/Calendar Event Query.app"
    mkdir -p "$app/Contents/MacOS" "$out/bin"
    install -m755 calendar-event-query "$app/Contents/MacOS/calendar-event-query"
    cp ${infoPlist} "$app/Contents/Info.plist"
    ln -s "$app/Contents/MacOS/calendar-event-query" "$out/bin/calendar-event-query"

    runHook postInstall
  '';

  meta = {
    description = "Query macOS calendar events in a time range";
    platforms = lib.platforms.darwin;
    mainProgram = "calendar-event-query";
  };
}
