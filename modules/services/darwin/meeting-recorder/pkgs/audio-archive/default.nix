{
  ffmpeg,
  lib,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "meeting-audio-archive";
  version = "1";
  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    substitute ${./archive-audio.py} "$out/bin/archive-audio" \
      --replace-fail '@PYTHON@' '${python3}/bin/python3' \
      --replace-fail '@FFMPEG@' '${ffmpeg}/bin/ffmpeg' \
      --replace-fail '@FFPROBE@' '${ffmpeg}/bin/ffprobe'
    chmod +x "$out/bin/archive-audio"

    runHook postInstall
  '';

  meta = {
    description = "Compress meeting recordings while preserving audio track timing";
    mainProgram = "archive-audio";
    platforms = lib.platforms.darwin;
  };
}
