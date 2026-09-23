{
  callPackage,
  python3,
  tmux,
  writeShellApplication,
}:
let
  hookLibrary = callPackage ../../../ai-agents/hooks/runtime { };
  python = python3.withPackages (_: [ hookLibrary ]);
in
writeShellApplication {
  name = "ai-agent-status";
  text = ''
    exec ${python}/bin/python ${./status.py} "$@" ${tmux}/bin/tmux
  '';
}
