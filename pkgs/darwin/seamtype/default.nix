{
  fetchurl,
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "seamtype";
  version = "0.1.15";

  src = fetchurl {
    url = "https://github.com/aimdevlee/seamtype/releases/download/v0.1.15/Seamtype-0.1.15.zip";
    hash = "sha256-/DjDWol0hnDUkIiGPHlFac3G+LLpWLp9AZOvj8H6G84=";
  };

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications"
    /usr/bin/ditto -x -k "$src" "$out/Applications"
    runHook postInstall
  '';

  meta = {
    description = "Automatic English, Korean and Japanese input method for macOS";
    homepage = "https://github.com/aimdevlee/seamtype";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
