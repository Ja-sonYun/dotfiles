{
  lib,
  stdenv,
  fetchFromGitHub,
  pkg-config,
  radare2,
}:
stdenv.mkDerivation {
  pname = "r2mcp";
  version = "1.8.8";

  src = fetchFromGitHub {
    owner = "radareorg";
    repo = "radare2-mcp";
    rev = "791d23880142801adf5fc0cf8791beb4cbba9505";
    hash = "sha256-ttx+lklMiXxFmSVAVAgPPuI3iMTLQGDacyakY3aVF4Q=";
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ radare2 ];
  enableParallelBuilding = true;

  postPatch = ''
    substituteInPlace src/Makefile \
      --replace-fail '    CFLAGS += -I/usr/local/include/libr -I/usr/local/include' "" \
      --replace-fail '    CFLAGS += -I$(shell brew --prefix)/include' ""
  '';

  makeFlags = [
    "-C"
    "src"
    "R2_LIBEXT=${lib.removePrefix "." stdenv.hostPlatform.extensions.sharedLibrary}"
  ];
  buildFlags = [ "libcore_r2mcp${stdenv.hostPlatform.extensions.sharedLibrary}" ];

  installPhase = ''
    runHook preInstall
    install -Dm755 src/libcore_r2mcp${stdenv.hostPlatform.extensions.sharedLibrary} \
      "$out/lib/radare2/last/libcore_r2mcp${stdenv.hostPlatform.extensions.sharedLibrary}"
    runHook postInstall
  '';

  meta = {
    description = "MCP core plugin for a live radare2 session";
    homepage = "https://github.com/radareorg/radare2-mcp";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
