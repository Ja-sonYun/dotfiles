{ pkgs, ... }:

let
  subagentSrc = "${pkgs.pi}/lib/node_modules/dotfiles-pi/node_modules/@earendil-works/pi-coding-agent/examples/extensions/subagent";
in
pkgs.runCommandLocal "pi-ext-subagent" { } ''
  mkdir -p $out/extension
  cp ${subagentSrc}/agents.ts $out/extension/agents.ts
  cp ${subagentSrc}/index.ts $out/extension/index.ts
  chmod u+w $out/extension/*.ts
  ${pkgs.patch}/bin/patch --batch --fuzz=0 -p1 -d $out/extension < ${./subagent.patch}
''
