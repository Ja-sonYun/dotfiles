{
  lib,
  apple-sdk_15,
  bintools-unwrapped,
  cups,
  fetchFromGitHub,
  installShellFiles,
  llvmPackages,
  stdenv,
  versionCheckHook,
  xxd,
}:
stdenv.mkDerivation {
  pname = "yabai";
  version = "7.1.25";

  src = fetchFromGitHub {
    owner = "AhsanFazal";
    repo = "yabai";
    rev = "ad0a12d63f639534a296a1d065b0d04979f1b4db";
    hash = "sha256-CFC9KuBw7oyOjL5t8D+JIdk6/cdSh91J/K/8XA3v3aE=";
  };

  __structuredAttrs = true;
  strictDeps = true;

  nativeBuildInputs = [
    installShellFiles
    xxd
  ];

  buildInputs = [
    apple-sdk_15
  ];

  enableParallelBuilding = false;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,share/icons/hicolor/scalable/apps}

    cp ./bin/yabai $out/bin/yabai
    cp ./assets/icon/icon.svg $out/share/icons/hicolor/scalable/apps/yabai.svg
    installManPage ./doc/yabai.1

    runHook postInstall
  '';

  postPatch =
    let
      arch = stdenv.hostPlatform.darwinArch;
      archSA = "${arch}${lib.optionalString stdenv.hostPlatform.isAarch64 "e"}";
      clangFlags = lib.concatStringsSep " " [
        "-isystem $(SDKROOT)/usr/include"
        "-isystem ${llvmPackages.libclang.lib}/lib/clang/*/include"
        "-isystem ${lib.getDev cups}/include"
        "-F$(SDKROOT)/System/Library/Frameworks"
        "-L$(SDKROOT)/usr/lib"
        "-Wl,-no_uuid"
      ];
    in
    ''
      substituteInPlace makefile \
        --replace-fail "-arch x86_64 -arch arm64e" "-arch ${archSA}" \
        --replace-fail "-arch x86_64 -arch arm64" "-arch ${arch}" \
        --replace-fail 'xcrun clang' 'clang ${clangFlags}'
    '';

  preBuild = lib.optionalString stdenv.hostPlatform.isAarch64 ''
    make ./src/osax/payload_bin.c ./src/osax/loader_bin.c "PATH=${bintools-unwrapped}/bin:${llvmPackages.clang-unwrapped}/bin:$PATH"
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  passthru.modules = {
    homeManager = import ./home-manager.nix;
    darwin = import ./darwin.nix;
  };

  meta = {
    description = "Tiling window manager for macOS based on binary space partitioning";
    homepage = "https://github.com/AhsanFazal/yabai";
    changelog = "https://github.com/AhsanFazal/yabai/blob/ad0a12d63f639534a296a1d065b0d04979f1b4db/CHANGELOG.md";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "yabai";
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
}
