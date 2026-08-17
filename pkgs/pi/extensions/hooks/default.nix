{ pkgs, ... }:

hooks:

let
  hooksJson = (pkgs.formats.json { }).generate "pi-hooks.json" hooks;
in
pkgs.runCommandLocal "pi-ext-hooks" { } ''
  mkdir -p $out
  cp ${./src/command-hooks.ts} $out/command-hooks.ts
  cp -R ${./src/events} $out/events
  cp ${./src/hook-contract.ts} $out/hook-contract.ts
  cp ${./src/hook-ui.ts} $out/hook-ui.ts
  cp ${./src/index.ts} $out/index.ts
  cp ${./src/state.ts} $out/state.ts
  cp ${hooksJson} $out/hooks.json
''
