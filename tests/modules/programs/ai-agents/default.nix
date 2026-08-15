{
  agenix-secrets,
  home-manager,
  nixlib,
  pkgs,
}:
let
  inherit (pkgs) lib;
  testPkgs = ((pkgs.extend nixlib.overlays.tool).extend agenix-secrets.overlays.default).extend (
    final: _prev: {
      notifycmd = final.writeShellScriptBin "notifycmd" "exit 0";
      skills = final.writeShellScriptBin "skills" "exit 0";
      pi-extensions = {
        hooks = final.writeTextDir "index.ts" "";
        mcp-adapter = final.writeTextDir "extension/index.ts" "";
        permission-system = final.writeTextDir "extension/index.ts" "";
      };
    }
  );
  testPackage = name: testPkgs.writeShellScriptBin name "exit 0";
  claudePackage = (testPackage "claude").overrideAttrs (_previous: {
    pname = "claude-code";
    version = "2.1.200";
  });
  scenarioArgs = {
    inherit
      agenix-secrets
      claudePackage
      home-manager
      testPackage
      testPkgs
      ;
  };
  shared = import ./shared.nix scenarioArgs;
  marketplace = import ./marketplace.nix scenarioArgs;
  manifest =
    name: scenario:
    testPkgs.writeText "${name}-expected-files.json" (
      builtins.toJSON {
        inherit name;
        inherit (scenario) actual expected;
      }
    );
  sharedManifest = manifest "shared AI tools" shared;
  marketplaceManifest = manifest "AWS marketplace" marketplace;
  managedFragment =
    configuration:
    let
      activation = configuration.config.home.activation.codexConfigMerge.data;
      words = lib.splitString " " (builtins.replaceStrings [ "\n" "\\" ] [ " " "" ] activation);
    in
    lib.findFirst (
      word: lib.hasSuffix "-codex-managed-settings.toml" word
    ) (throw "Codex activation does not reference a managed settings fragment") words;
  testPython = testPkgs.python3.withPackages (python: [ python.tomlkit ]);
  codexModule = ../../../../modules/programs/codex;
in
testPkgs.runCommand "ai-tools-tests"
  {
    nativeBuildInputs = [ testPython ];
  }
  ''
    set -euo pipefail

    test_python=${testPython}/bin/python3

    merge_codex() {
      "$test_python" ${codexModule}/merge-config-toml.py \
        "$1" "$2" \
        "$3-mcp.json" \
        "$3-model-provider.json" \
        "$3-marketplace.json" \
        "$3-plugin.json"
    }

    export SHARED_CODEX_CONFIG="$TMPDIR/shared-config.toml"
    export MARKETPLACE_CODEX_CONFIG="$TMPDIR/marketplace-config.toml"

    merge_codex \
      "$SHARED_CODEX_CONFIG" \
      ${lib.escapeShellArg (managedFragment shared.configuration)} \
      "$TMPDIR/shared"
    merge_codex \
      "$MARKETPLACE_CODEX_CONFIG" \
      ${lib.escapeShellArg (managedFragment marketplace.configuration)} \
      "$TMPDIR/marketplace"

    "$test_python" ${codexModule}/test_merge_config_toml.py
    "$test_python" ${../../../lib/check-generated-files.py} \
      ${sharedManifest} \
      ${marketplaceManifest}

    printf 'PASS: Codex, Claude, and Pi generated the expected AI tool files.\n' > "$out"
  ''
