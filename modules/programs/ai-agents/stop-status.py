#!/usr/bin/env python3

import json
import subprocess
import sys


def _state_for_stop(hook_input: dict[str, object]) -> str:
    message = str(hook_input.get("last_assistant_message") or "")
    return "waiting" if "<proposed_plan>" in message.lower() else "idle"


def _notification_for_stop(
    hook_input: dict[str, object],
    client: str,
) -> dict[str, str]:
    if _state_for_stop(hook_input) == "waiting":
        return {
            "type": "desktop-notification",
            "title": f"{client}: Action Required",
            "message": "Awaiting your input",
            "sound": "Funk",
        }
    return {
        "type": "desktop-notification",
        "title": f"{client}: Turn Complete",
        "message": "Done",
        "sound": "Glass",
    }


def _run(command: str, *args: str) -> None:
    subprocess.run(
        [command, *args],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        _selftest()
        return 0
    if len(sys.argv) != 4:
        return 2

    try:
        hook_input = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        hook_input = {}
    if not isinstance(hook_input, dict):
        hook_input = {}

    status_script, notify_command, client = sys.argv[1:]
    _run(status_script, _state_for_stop(hook_input))
    _run(notify_command, json.dumps(_notification_for_stop(hook_input, client)))
    return 0


def _selftest() -> None:
    assert _state_for_stop({}) == "idle"
    assert _state_for_stop({"last_assistant_message": "Done."}) == "idle"
    assert _state_for_stop({"last_assistant_message": "<proposed_plan>\nplan"}) == "waiting"
    assert _state_for_stop({"last_assistant_message": None}) == "idle"
    assert _notification_for_stop({}, "Codex") == {
        "type": "desktop-notification",
        "title": "Codex: Turn Complete",
        "message": "Done",
        "sound": "Glass",
    }
    assert _notification_for_stop(
        {"last_assistant_message": "<proposed_plan>\nplan"},
        "Codex",
    ) == {
        "type": "desktop-notification",
        "title": "Codex: Action Required",
        "message": "Awaiting your input",
        "sound": "Funk",
    }


if __name__ == "__main__":
    sys.exit(main())
