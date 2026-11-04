{
  apple-sdk_15,
  fetchFromGitHub,
  fetchurl,
  lib,
  stdenv,
  swift,
}:
let
  runtimeId = "3.13.15-d66c67f16148c745";
  runtimePath = "/Library/RemCTL/Python/${runtimeId}";
  runtimeExecutable = "${runtimePath}/bin/python3.13";
  runtime = stdenv.mkDerivation {
    pname = "remctl-python";
    version = "3.13.15";
    src = fetchurl {
      url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260929/cpython-3.13.15%2B20260929-aarch64-apple-darwin-install_only_stripped.tar.gz";
      sha256 = "d66c67f16148c7454b1509c32747175f7669c8b8e105b97b92a0000d66af6e6e";
    };
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p "$out"
      cp -R . "$out/"
    '';
  };
in
stdenv.mkDerivation {
  pname = "remctl";
  version = "2.5.0";
  src = fetchFromGitHub {
    owner = "viticci";
    repo = "remctl";
    rev = "d9e934bf25c8f30a620f659268faa9acc4f24e04";
    sha256 = "0nwn3iz87csdi2s0l4vp8nq90sy9w3x540kxc5imr0j7ngqq60kx";
  };
  nativeBuildInputs = [ swift ];
  buildInputs = [ apple-sdk_15 ];
  buildPhase = ''
    runHook preBuild
    mkdir -p native ReminderKit.framework
    ${runtime}/bin/python3 -B -I -S ${./framework-stub.py} remctl-private.m ReminderKit.framework/ReminderKit.tbd
    swiftc -target arm64-apple-macosx14.0 -O -framework EventKit -framework Foundation remctl-bridge.swift -o native/remctl-bridge
    swiftc -target arm64-apple-macosx14.0 -O -framework AppKit -framework Foundation remctl-permissions.swift -o native/remctl-permissions
    clang -fobjc-arc -O -F. -framework Foundation -framework AppKit -framework ReminderKit remctl-private.m -o native/remctl-private
    ${runtime}/bin/python3 -B -I -S scripts/build_capability_archive.py --source-root "$PWD" --output "$PWD/capability.pyz"
    swiftc -target arm64-apple-macosx14.0 -O -framework Foundation -framework AppKit -framework CoreServices -framework EventKit -framework Security -framework CryptoKit \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __rctl_pyz -Xlinker "$PWD/capability.pyz" \
      remctl-capability-host.swift -o native/remctl-capability-host
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    client="$out/libexec/remctl"
    app="$out/Applications/RemCTL Capability Host.app/Contents"
    mkdir -p "$client" "$app/MacOS" "$app/Resources/CapabilityRuntime/bin" "$out/bin"
    cp remctl remctl_*.py remctl_*.html "$client/"
    cp -R assets plugins .agents "$client/"
    cp native/remctl-permissions "$client/"
    cp remctl-capability-host-Info.plist "$app/Info.plist"
    cp native/remctl-capability-host "$app/MacOS/RemCTL Capability Host"
    cp native/remctl-bridge native/remctl-private "$app/Resources/CapabilityRuntime/bin/"
    cp assets/remctl.icns "$app/Resources/"
    cp -R plugins .agents "$app/Resources/"
    printf '%s\n' 'portable-user' > "$app/Resources/remctl-capability-host-socket-path"
    printf '%s\n' '${runtimeExecutable}' > "$app/Resources/remctl-capability-python-path"
    cat > "$out/bin/remctl" <<EOF
    #!${stdenv.shell}
    exec ${lib.escapeShellArg runtimeExecutable} "$client/remctl" "\$@"
    EOF
    chmod +x "$out/bin/remctl"
    runHook postInstall
  '';
  passthru = { inherit runtime runtimePath; };
  meta = {
    description = "Apple Reminders CLI and MCP server";
    homepage = "https://github.com/viticci/remctl";
    mainProgram = "remctl";
    platforms = [ "aarch64-darwin" ];
  };
}
