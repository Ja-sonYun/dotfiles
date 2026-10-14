{ pkgs, ... }:

pkgs.runCommandLocal "pi-ext-permissions" { } ''
  mkdir -p "$out"
  cp ${./.}/*.ts "$out/"
''
