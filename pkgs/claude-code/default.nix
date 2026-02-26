{ pkgs, ... }:
let
  outputHash = pkgs.hashfile."claude-code";
in

pkgs.lib.npm.mkNpmGlobalPackageDerivation {
  inherit pkgs outputHash;
  name = "claude-code";
  packages = [
    "@anthropic-ai/claude-code@2.1.61"
  ];
  exposedBinaries = [
    "claude"
  ];
  postInstall = ''
    wrapProgram $out/bin/claude           \
      --set DISABLE_BUG_COMMAND         1 \
      --set DISABLE_INSTALLATION_CHECKS 1 \
      --set DISABLE_AUTOUPDATER         1 \
      --set DISABLE_ERROR_REPORTING     1 \
      --set DISABLE_COST_WARNINGS       1 \
      --set DISABLE_TELEMETRY           1
  '';
  postFixup =
    { node
    ,
    }:
    ''
      # Use global env rather than coreutils's env
      sed -i '1s@^#!/.*/env.*@#!/usr/bin/env -S ${node}/bin/node --no-warnings --enable-source-maps @' node_modules/claude-code/lib/node_modules/@anthropic-ai/claude-code/cli.js
    '';
}
