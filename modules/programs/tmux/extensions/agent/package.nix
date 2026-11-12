{
  lib,
  callPackage,
  python3,
  tmux,
  jev,
  tool,
  writeShellApplication,
  logSocket ? "",
  judgeEnvironment ? { },
}:
let
  hookLibrary = callPackage ../../../ai-agents/hooks/runtime { };
  python = python3.withPackages (_: [ hookLibrary ]);
in
writeShellApplication {
  name = "ai-agent-status";
  text = ''
    export TMUX_LOG_SOCKET=${lib.escapeShellArg logSocket}
    export AI_AGENT_JUDGE_COMMAND="$0"
    export AI_AGENT_JEV=${lib.getExe jev}
    if [[ "''${1:-}" == --judge ]]; then
      shift
      if [[ "''${1:-}" == worker ]]; then
        :
        ${tool.shell.util.shellExports judgeEnvironment}
      fi
      exec ${python}/bin/python ${./.}/judge.py "$@" ${tmux}/bin/tmux
    fi
    if [[ "''${1:-}" != --statusline && -n "''${TMUX_PANE:-}" && "''${AI_AGENT_SUBAGENT:-}" != 1 && ( "''${AI_AGENT_CLIENT:-}" == Antigravity || "''${AI_AGENT_CLIENT:-}" == Claude || "''${AI_AGENT_CLIENT:-}" == Codex ) ]]; then
      exec "$1" --hook ${python}/bin/python ${./.}/status.py "$@" ${tmux}/bin/tmux
    fi
    exec ${python}/bin/python ${./.}/status.py "$@" ${tmux}/bin/tmux
  '';
}
