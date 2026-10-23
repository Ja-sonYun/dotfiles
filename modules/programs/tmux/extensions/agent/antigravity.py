import os
import select
import subprocess
import sys
import uuid
from contextlib import closing

from diagnostics import log_event


def main() -> None:
    observer = sys.argv[1]
    executable = sys.argv[2]
    arguments = sys.argv[2:]
    if not os.environ.get("TMUX_PANE"):
        os.execv(executable, arguments)
    if (
        os.environ.get("ANTIGRAVITY_RUN_ID")
        or os.environ.get("AI_AGENT_SUBAGENT") == "1"
    ):
        os.environ["AI_AGENT_SUBAGENT"] = "1"
        os.execv(executable, arguments)

    os.environ["ANTIGRAVITY_RUN_ID"] = uuid.uuid4().hex
    os.environ["ANTIGRAVITY_LIFECYCLE"] = "start"
    owner = os.getpid()
    ready, notify = os.pipe()
    watcher = os.fork()
    if watcher == 0:
        os.close(ready)
        os.setsid()
        # Register before exec so even an immediate exit is observed without PID polling.
        with closing(select.kqueue()) as queue:
            queue.control(
                [
                    select.kevent(
                        owner,
                        filter=select.KQ_FILTER_PROC,
                        flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                        fflags=select.KQ_NOTE_EXIT,
                    )
                ],
                0,
            )
            os.write(notify, b"1")
            os.close(notify)
            with open(os.devnull, "r+b") as null:
                for descriptor in (0, 1, 2):
                    os.dup2(null.fileno(), descriptor)
            queue.control(None, 1)
        os.environ["ANTIGRAVITY_LIFECYCLE"] = "end"
        os.execv("/bin/sh", ["sh", "-c", observer])

    os.close(notify)
    with os.fdopen(ready, "rb") as pipe:
        registered = pipe.read(1)
    if registered != b"1":
        os.waitpid(watcher, 0)
        log_event("tmux.agent.antigravity", "error", "observer_registration_failed")
        raise RuntimeError("Cannot observe Antigravity process exit")
    result = subprocess.run(
        observer,
        shell=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode:
        log_event(
            "tmux.agent.antigravity",
            "error",
            "observer_failed",
            exit_code=result.returncode,
        )
    os.environ.pop("ANTIGRAVITY_LIFECYCLE")
    os.execv(executable, arguments)


if __name__ == "__main__":
    main()
