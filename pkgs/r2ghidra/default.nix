{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  flex,
  bison,
  zlib,
  radare2,
}:
let
  ghidraNative = fetchFromGitHub {
    owner = "radareorg";
    repo = "ghidra-native";
    rev = "0.6.4";
    hash = "sha256-DFvHM/erGE9wFjcB3Dlyhv4oebzXwe2yGG+GzLaY7hU=";
  };
  pugixml = fetchFromGitHub {
    owner = "zeux";
    repo = "pugixml";
    rev = "v1.15";
    hash = "sha256-t/57lg32KgKPc7qRGQtO/GOwHRqoj78lllSaE/A8Z9Q=";
  };
  # exact diff_files from subprojects/ghidra-native.wrap (0022 is .disabled)
  patches = [
    "0001-space-after-comma"
    "0002-make-sleigharch-public"
    "0004-public-fields"
    "0006-readonly-warning"
    "0010-null-subflow"
    "0020-Fix-double-free-crash-when-deinitializing-multiple-X"
    "0023-Undef-LoadImage-for-windows"
    "0024-ignore-symbol-beyond-space"
    "0044-bad-unicode-codepoint"
    "0055-datatype-clone"
    "0056-nullderef-workaround"
    "0080-getparent-flow"
    "0090-nocasts-warnings"
    "0091-decompiler-xml-packer"
    "0092-badvar-segfault"
    "0093-no-virtual-destructor"
    "0100-CHAR-windows"
  ];
in
stdenv.mkDerivation {
  pname = "r2ghidra";
  version = "6.1.4";

  src = fetchFromGitHub {
    owner = "radareorg";
    repo = "r2ghidra";
    rev = "6.1.4";
    hash = "sha256-uVMsONXethTq/BL9MBQkDP3iJ6t25PEnpeD/Y17dpxM=";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    flex
    bison
  ];
  buildInputs = [
    zlib
    radare2
  ];

  postPatch = ''
    cp -r --no-preserve=mode ${ghidraNative}/. subprojects/ghidra-native
    cp -r --no-preserve=mode subprojects/packagefiles/ghidra-native/. subprojects/ghidra-native
    # case-insensitive APFS: the VERSION file shadows libc++ <version>
    find subprojects/ghidra-native -type f -iname version -delete
    ${lib.concatMapStringsSep "\n" (
      p: "patch -p1 -d subprojects/ghidra-native < subprojects/ghidra-native/patches/${p}.patch"
    ) patches}

    cp -r --no-preserve=mode ${pugixml}/. subprojects/pugixml
    cp -r --no-preserve=mode subprojects/packagefiles/pugixml/. subprojects/pugixml

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
