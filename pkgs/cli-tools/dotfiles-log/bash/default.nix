{
  lib,
  stdenv,
  bash,
}:
stdenv.mkDerivation {
  pname = "dotfiles-log-bash";
  version = "0.1.0";
  src = ./.;
  dontConfigure = true;
  dontFixup = true;
  buildPhase = ''
    runHook preBuild
    $CC -O2 -fPIC -pthread \
      -I${../clients/native} \
      -I${lib.getDev bash}/include/bash \
      -I${lib.getDev bash}/include/bash/include \
      ${if stdenv.hostPlatform.isDarwin then "-bundle -undefined dynamic_lookup" else "-shared"} \
      logger.c -o dotfiles_log.so
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 dotfiles_log.so $out/lib/bash/dotfiles_log.so
    runHook postInstall
  '';
}
