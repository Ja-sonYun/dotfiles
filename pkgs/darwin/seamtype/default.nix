{
  apple-sdk_15,
  fetchSwiftPMDeps,
  fetchurl,
  fetchzip,
  lib,
  sqlite,
  stdenv,
  swift,
  swiftpm,
  writeText,
}:
let
  releaseBundle = fetchurl {
    url = "https://github.com/aimdevlee/seamtype/releases/download/v0.1.15/Seamtype-0.1.15.zip";
    hash = "sha256-/DjDWol0hnDUkIiGPHlFac3G+LLpWLp9AZOvj8H6G84=";
  };
  llamaFramework = fetchzip {
    name = "llama.xcframework";
    url = "https://github.com/azooKey/llama.cpp/releases/download/b4846/signed-llama.xcframework.zip";
    hash = "sha256-WeEPFre4saiomq/pGIrX2rSakHuozsIH6pEO8J924s8=";
  };
  sqliteModuleMap = writeText "SeamtypeSQLite.modulemap" ''
    module SeamtypeSQLite [system] {
      header "${lib.getDev sqlite}/include/sqlite3.h"
      export *
      link "sqlite3"
    }
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "seamtype";
  version = "0.1.15";

  src = fetchurl {
    name = "seamtype-${finalAttrs.version}.tar.gz";
    url = "https://codeload.github.com/nyttastudio/araso/tar.gz/1ad04201747a503feedf65b1208eb37406996103";
    hash = "sha256-wUaoE38adG9JNQ/gUrXh1A0VEbSnwuYy4qS2U7aOu3U=";
  };

  patches = [
    ./patches/composition-tab.patch
    ./patches/number-composition.patch
  ];

  swiftpmDeps = fetchSwiftPMDeps {
    inherit (finalAttrs) src;
    hash = "sha256-yLicjUziUAwQzJHpvPoASLhJAkU0C3HW8Lr8pKOhNVI=";
  };

  nativeBuildInputs = [
    swift
    swiftpm
  ];
  buildInputs = [
    apple-sdk_15
    sqlite
  ];
  swiftpmFlags = [
    "--product"
    "Seamtype"
    "-Xcc"
    "-fmodule-map-file=${sqliteModuleMap}"
  ];

  postPatch = ''
    substituteInPlace Sources/Seamtype/TextReplacements.swift \
      --replace-fail 'import SQLite3' 'import SeamtypeSQLite'

    cp -RL --no-preserve=mode Packages mutable-packages
    unlink Packages
    mv mutable-packages Packages

    cp -R --no-preserve=mode ${llamaFramework} \
      Packages/AzooKeyKanaKanjiConverter/llama.xcframework

    # SwiftPM fetches declared binary targets even when their trait is disabled.
    # https://github.com/swiftlang/swift-package-manager/blob/swift-6.3.3-RELEASE/Sources/Workspace/Workspace%2BBinaryArtifacts.swift
    substituteInPlace Packages/AzooKeyKanaKanjiConverter/Package.swift \
      --replace-fail \
        'url: "https://github.com/azooKey/llama.cpp/releases/download/b4846/signed-llama.xcframework.zip",' \
        'path: "llama.xcframework"' \
      --replace-fail \
        'checksum: "db3b13169df8870375f212e6ac21194225f1c85f7911d595ab64c8c790068e0a"' \
        ""
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications"
    /usr/bin/ditto -x -k ${releaseBundle} "$out/Applications"
    app="$out/Applications/Seamtype.app"
    chmod -R u+w "$app"
    binPath=$(swiftpmBinPath)
    install -m755 "$binPath/Seamtype" "$app/Contents/MacOS/Seamtype"

    runHook postInstall
  '';

  # Sign after the Swift fixup hook rewrites runtime library paths.
  # https://github.com/NixOS/nixpkgs/blob/5adc50831c259f87faeb09ddf930d43597197473/doc/languages-frameworks/swift.section.md#hooks
  postFixup = ''
    /usr/bin/codesign --force --sign - "$out/Applications/Seamtype.app"
  '';

  meta = {
    description = "Automatic English, Korean and Japanese input method for macOS";
    homepage = "https://github.com/aimdevlee/seamtype";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
})
