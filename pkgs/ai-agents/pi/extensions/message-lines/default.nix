{ pkgs, ... }:

pkgs.runCommandLocal "pi-ext-message-lines" { } ''
  mkdir -p "$out"
  cp ${./index.ts} "$out/index.ts"
''
