{ pkgs, ... }:

providers:

let
  providersJson = (pkgs.formats.json { }).generate "pi-providers.json" providers;
in
pkgs.runCommandLocal "pi-ext-providers" { } ''
  mkdir -p $out
  cp ${./index.ts} $out/index.ts
  cp ${providersJson} $out/providers.json
''
