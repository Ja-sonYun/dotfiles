{ pkgs, ... }:

pkgs.runCommandLocal "pi-ext-tool-summaries" { } ''
  mkdir -p "$out"
  cp ${./index.ts} "$out/index.ts"
  cp ${./permission-ui.ts} "$out/permission-ui.ts"
''
