{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  flex,
  bison,
  git,
  python3,
  zlib,
  radare2,
}:
let
  ghidraNative = fetchFromGitHub {
    owner = "radareorg";
    repo = "ghidra-native";
    rev = "0.7.2";
    hash = "sha256-/ubxU2uWUr1brql4K9ydS4z1aH4AJyJw2y7cAPFXczE=";
  };
in
stdenv.mkDerivation {
  pname = "r2ghidra";
  version = "6.2.6";

  src = fetchFromGitHub {
    owner = "radareorg";
    repo = "r2ghidra";
    rev = "6.2.6";
    hash = "sha256-ttdU6oHihazZb+RL2cRsWZ2T470O6ECdU7CsZQXAH8g=";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    flex
    bison
    git
    python3
  ];
  buildInputs = [
    zlib
    radare2
  ];

  postPatch = ''
    cp -r --no-preserve=mode ${ghidraNative}/. subprojects/ghidra-native

    # upstream installs into the read-only radare2 store path; redirect into $out
    substituteInPlace meson.build \
      --replace-fail "r2_plugdir = res.stdout().strip()" "r2_plugdir = get_option('prefix') / 'lib/radare2/last'"
  '';

  meta = {
    description = "Ghidra decompiler plugin for radare2 (pdg)";
    homepage = "https://github.com/radareorg/r2ghidra";
    license = lib.licenses.asl20;
    platforms = lib.platforms.unix;
  };
}
