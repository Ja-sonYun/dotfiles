{ pkgs, ... }:

pkgs.runCommandLocal "pi-ext-redact" { } ''
  mkdir -p "$out"
  cp ${./.}/*.ts "$out/"
''
