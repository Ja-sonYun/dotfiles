{
  lib,
  rustPlatform,
  nodejs_22,
  typescript,
  pi-runtime,
}:
rustPlatform.buildRustPackage {
  pname = "agent-hub";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;
  doCheck = false;
  nativeBuildInputs = [ typescript ];

  postBuild = ''
    mkdir -p typescript-src
    cp pi/runner.mts pi/package.json typescript-src/
    cp ${../pi.ts} typescript-src/extension.ts
    ln -s ${pi-runtime}/lib/node_modules/dotfiles-pi/node_modules typescript-src/node_modules
    tsc --strict --noEmitOnError --target ES2022 --module NodeNext \
      --moduleResolution NodeNext --types node --typeRoots typescript-src/node_modules/@types --outDir compiled-pi \
      typescript-src/runner.mts typescript-src/extension.ts
  '';

  postInstall = ''
    mkdir -p "$out/share/agent-hub/pi"
    cp compiled-pi/runner.mjs pi/package.json "$out/share/agent-hub/pi/"
  '';

  passthru = {
    node = "${nodejs_22}/bin/node";
    sdk = "${pi-runtime}/lib/node_modules/dotfiles-pi/node_modules/@earendil-works/pi-coding-agent/dist/index.js";
    aiSdk = "${pi-runtime}/lib/node_modules/dotfiles-pi/node_modules/@earendil-works/pi-ai/dist/index.js";
  };

  meta = {
    description = "Read-only Pi agent monitor and tmux terminal interface";
    mainProgram = "agent-hub";
    platforms = [ "aarch64-darwin" ];
  };
}
