{ pkgs, ... }:

let
  subagentSrc = "${pkgs.pi}/node_modules/pi/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/subagent";
in
pkgs.runCommandLocal "pi-ext-subagent" { } ''
  mkdir -p $out/extension
  cp ${subagentSrc}/agents.ts $out/extension/agents.ts
  cp ${subagentSrc}/index.ts $out/extension/index.ts
''
