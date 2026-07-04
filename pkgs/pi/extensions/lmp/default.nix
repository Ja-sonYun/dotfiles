{ pkgs, ... }:

# Source-only extension (no deps): pi loads ./index.ts directly via jiti.
pkgs.runCommandLocal "pi-ext-lmp" { } ''
  mkdir -p $out
  cp ${./index.ts} $out/index.ts
''
