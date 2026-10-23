{
  lib,
  callPackage,
  python3,
  tmux,
  writeShellApplication,
  logSocket ? "",
}:
let
  hookLibrary = callPackage ../../../ai-agents/hooks/runtime { };
  python = python3.withPackages (_: [ hookLibrary ]);
in
writeShellApplication {
  name = "ai-agent-status";
  text = ''
    export TMUX_LOG_SOCKET=${lib.escapeShellArg logSocket}
    if [[ "''${AI_AGENT_CLIENT:-}" == Antigravity && -n "''${TMUX_PANE:-}" && "''${AI_AGENT_SUBAGENT:-}" != 1 ]]; then
      exec "$1" --hook ${python}/bin/python ${./.}/status.py "$@" ${tmux}/bin/tmux
    fi
    exec ${python}/bin/python ${./.}/status.py "$@" ${tmux}/bin/tmux
  '';
}
