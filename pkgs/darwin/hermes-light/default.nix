{
  callPackage,
  electron,
  lib,
  modelLabelPatch,
  python3,
  writeText,
}:
let
  version = "0.23.2";
  rev = "ae2a81ccc00e9b7c06301523e5bb09608397149c";
  upstream = builtins.getFlake "github:NousResearch/hermes-agent/${rev}";
  inherit (upstream.packages.aarch64-darwin.minimal) hermesNpmLib python;
  inherit (upstream.inputs) uv2nix pyproject-nix pyproject-build-systems;
  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = hermesNpmLib.pythonSrc; };
  iconPackages = (callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
    lib.composeManyExtensions [
      pyproject-build-systems.overlays.default
      (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
    ]
  );
  icons = callPackage (upstream.outPath + "/nix/icons.nix") {
    venv = iconPackages.mkVirtualEnv "hermes-icon-tools" {
      pillow = [ ];
      resvg-py = [ ];
    };
  };
  stamp = writeText "hermes-light-install-stamp.json" (
    builtins.toJSON {
      schemaVersion = 2;
      commit = rev;
      commitDate = upstream.lastModified;
      branch = null;
      dirty = false;
      builtAt = null;
      baseVersion = version;
      displayVersion = version;
      distance = 0;
      source = "nix";
      distribution = "nix";
      updateMechanism = "external";
      payload = "light";
      tag = "v${version}";
    }
  );
in
hermesNpmLib.buildPnpmPackage {
  pname = "hermes-light";
  inherit version;
  patches = [
    modelLabelPatch
    ./remote-client.patch
  ];
  pnpmDeps = hermesNpmLib.pnpmDeps.overrideAttrs {
    outputHash = "sha256-0DFhYHo5HDps1hz6Haqv3cQfA1ug10LL/ohxKZGSDlw=";
  };
  dirs = [
    "apps/desktop"
    "apps/shared"
    "scripts/build"
    "scripts/msix-shared.mjs"
    "scripts/release-content-types.json"
  ];
  nativeBuildInputs = [ python3 ];
  HERMES_DESKTOP_VARIANT = "light";
  buildPhase = ''
    runHook preBuild
    patchShebangs .
    ${lib.getExe hermesNpmLib.node-gyp} rebuild \
      --directory=apps/desktop/node_modules/node-pty --runtime=electron \
      --target=${electron.version} --nodedir=${electron.headers} --arch=arm64 --offline
    node apps/desktop/scripts/stage-native-deps.mjs --source "$PWD" \
      --out "$TMPDIR/native" --platform darwin --arch arm64
    node scripts/build/desktop.mjs --source "$PWD" --platform darwin \
      --out "$PWD/apps/desktop/dist" --native-deps "$TMPDIR/native" \
      --icons ${icons} --stamp ${stamp}
    runHook postBuild
  '';
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    app="$out/Applications/Hermes Light.app"
    mkdir -p "$out/Applications"
    cp -R "${electron}/Applications/Electron.app" "$app"
    chmod -R u+w "$app"
    resources="$app/Contents/Resources"
    mkdir -p "$resources/app"
    cp -R apps/desktop/dist "$resources/app/"
    cd apps/desktop
    node -e 'const fs = require("node:fs"), p = require("./package.json");
      const id = require("./product-identity.cjs");
      fs.writeFileSync(process.argv[1], JSON.stringify({...p, name: id.appNamePascal,
        productName: id.displayName, version: "${version}"}))' "$resources/app/package.json"
    cp ${stamp} "$resources/install-stamp.json"
    cp ${icons}/apps/desktop/assets/icon.icns "$resources/electron.icns"
    plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.nousresearch.hermes-light" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Hermes Light" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Hermes Light" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "$plist"
    /usr/bin/codesign --force --deep --sign - "$app"
    runHook postInstall
  '';
  meta.platforms = [ "aarch64-darwin" ];
}
