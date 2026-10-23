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
  logClientSource ? null,
}:
stdenv.mkDerivation {
  pname = "yabai";
  version = "7.1.25";

  src = fetchFromGitHub {
    owner = "asmvik";
    repo = "yabai";
    rev = "dd845723416f5fe92af49fad5ebab00369e07edd";
    hash = "sha256-RPiGAuJS+tGsexekIzwgKYf/v+kA3lVn0+qMVIMC2Vk=";
  };

  patches = [
    ./patches/macos-27.patch
    ./patches/sa-response-deadline.patch
    ./patches/fullscreen-transition-waits.patch
    ./patches/ax-geometry-errors.patch
    ./patches/response-shutdown.patch
  ]
  ++ lib.optional (logClientSource != null) ./patches/shared-logging.patch;

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
  # The upstream install target builds the release binary without installing it.
  buildFlags = [ "install" ];

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
      ];
    in
    ''
      ${lib.optionalString (logClientSource != null) ''
        cp ${logClientSource}/native/client.h src/misc/dotfiles_log_client.h
        cp ${./logging.h} src/misc/dotfiles_log.h
      ''}
      substituteInPlace makefile \
        --replace-fail "-arch x86_64 -arch arm64e" "-arch ${archSA}" \
        --replace-fail "-arch x86_64 -arch arm64" "-arch ${arch} -Wl,-no_uuid" \
        --replace-fail 'xcrun clang' 'clang ${clangFlags}'
    '';

  preBuild = lib.optionalString stdenv.hostPlatform.isAarch64 ''
    make ./src/osax/payload_bin.c ./src/osax/loader_bin.c "PATH=${bintools-unwrapped}/bin:${llvmPackages.clang-unwrapped}/bin:$PATH"
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  meta = {
    description = "Tiling window manager for macOS based on binary space partitioning";
    homepage = "https://github.com/asmvik/yabai";
    changelog = "https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/CHANGELOG.md";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "yabai";
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
}
