{
  apple-sdk_15,
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "audio-process-watcher";
  version = "0.1.0";

  src = ./.;

  strictDeps = true;
  dontConfigure = true;

  buildInputs = [ apple-sdk_15 ];

  buildPhase = ''
    runHook preBuild

    $CC \
      -fobjc-arc \
      -mmacosx-version-min=14.2 \
      -O2 \
      -framework CoreAudio \
      -framework Foundation \
      main.m \
      -o audio-process-watcher

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    install -m755 audio-process-watcher $out/bin/audio-process-watcher

    runHook postInstall
  '';

  meta = {
    description = "Publish per-process macOS microphone activity changes";
    platforms = lib.platforms.darwin;
    mainProgram = "audio-process-watcher";
  };
}
