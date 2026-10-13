{ pkgs, ... }:

pkgs.runCommandLocal "pi-ext-subagent" { } ''
  mkdir -p "$out"
  cp ${./.}/{index,agents,permissions}.ts ${./.}/LICENSE "$out/"
''
