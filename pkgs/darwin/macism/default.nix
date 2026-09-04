{
  fetchurl,
  lib,
  stdenvNoCC,
}:

let
  version = "3.1.1";
  sources = {
    aarch64-darwin = fetchurl {
      url = "https://github.com/laishulu/macism/releases/download/v${version}/macism-arm64";
      hash = "sha256-WvEn3ZxYV7vWO4lNMaLrlsnOac9tIY8X+ZKuRdQu3eo=";
    };
    x86_64-darwin = fetchurl {
      url = "https://github.com/laishulu/macism/releases/download/v${version}/macism-x86_64";
      hash = "sha256-PU0XgSa3+mLYPBrttnZEyrfjoeDuRSSEzu10ZJyMwoo=";
    };
  };
  src = sources.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation {
  pname = "macism";
  inherit version src;

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    cp $src $out/bin/macism
    chmod +x $out/bin/macism
  '';

  meta = {
    description = "Reliable macOS input source manager";
    homepage = "https://github.com/laishulu/macism";
    license = lib.licenses.mit;
    mainProgram = "macism";
    platforms = lib.platforms.darwin;
  };
}
