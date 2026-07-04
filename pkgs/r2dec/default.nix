{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchzip,
  meson,
  ninja,
  pkg-config,
  radare2,
}:
let
  # meson wrap pulls quickjs-ng offline; sandbox blocks the download.
  quickjs = fetchzip {
    url = "https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.8.0.tar.gz";
    hash = "sha256-o0Cpy+20EqNdNENaYlasJcKIGU7W4RYBcTMsQwFTUNc=";
  };
in
stdenv.mkDerivation {
  pname = "r2dec";
  version = "6.1.4";

  src = fetchFromGitHub {
    owner = "wargio";
    repo = "r2dec-js";
    rev = "6.1.4";
    hash = "sha256-FR41dy7pK70ZFKw4ky8yF02Ulkk32BQFNvZ0egnu6JU=";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
  ];
  buildInputs = [ radare2 ];

  postPatch = ''
    cp -r --no-preserve=mode ${quickjs}/. subprojects/libquickjs
    cp -r --no-preserve=mode subprojects/packagefiles/libquickjs/. subprojects/libquickjs
  '';

  mesonFlags = [ "-Dr2_plugdir=${placeholder "out"}/lib/radare2/last" ];

  meta = {
    description = "r2dec decompiler plugin for radare2 (pdd)";
    homepage = "https://github.com/wargio/r2dec-js";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.unix;
  };
}
