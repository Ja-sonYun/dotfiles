import json
import os
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from pathlib import Path


def pane_metadata(tmux: str, socket: str, pane: str) -> dict[str, object]:
    if not socket or not pane:
        return {}
    output = subprocess.run(
        [
            tmux,
            "-S",
            socket,
            "show-options",
            "-p",
            "-q",
            "-v",
            "-t",
            pane,
            "@agent_conversation",
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=0.5,
    ).stdout
    metadata = json.loads(output or "{}")
    if not isinstance(metadata, dict):
        raise ValueError("Invalid pane conversation metadata")
    return metadata


def codex_title(session_id: str) -> str:
    # https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/thread-store/src/local/helpers.rs#L201
    home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
    database_uri = (home / "state_5.sqlite").resolve().as_uri() + "?mode=ro"
    with closing(sqlite3.connect(database_uri, uri=True, timeout=0.2)) as database:
        database.create_function("strip", 1, str.strip, deterministic=True)
        row = database.execute(
            "SELECT history_mode, name, "
            "CASE WHEN strip(title) != '' AND strip(title) != strip(first_user_message) "
            "THEN strip(title) END FROM threads WHERE id = ?",
            (session_id,),
        ).fetchone()
    if row is None:
        return ""
    mode, name, legacy_title = row
    if mode == "paginated":
        return (name or "").strip()
    if mode != "legacy":
        raise ValueError("Unsupported Codex thread storage mode")
    if legacy_title:
        return legacy_title
    title = ""
    try:
        with (home / "session_index.jsonl").open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(entry, dict) and entry.get("id") == session_id:
                    value = entry.get("thread_name")
                    if isinstance(value, str):
                        title = value.strip()
    except FileNotFoundError:
        pass
    return title


def application_input(
    client: str, session_id: str, title: str | None, cwd: str
) -> dict[str, str | None]:
    return {
        "app": client,
        "event": "conversation_title",
        "session_id": session_id,
        "title": "(untitled)" if title == "" else title,
        "cwd": cwd,
    }


def main() -> int:
    started = time.monotonic()
    observer = len(sys.argv) == 3 and sys.argv[1] == "--observe"
    if not observer and not (len(sys.argv) == 4 and sys.argv[1] == "--hook"):
        return 2
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        return 1
    tmux = sys.argv[-1]
    metadata: dict[str, object] = {}
    if observer:
        socket = payload.get("tmux_socket", "")
        pane = payload.get("pane_id", "")
        if not isinstance(socket, str) or not isinstance(pane, str):
            return 1
        metadata = pane_metadata(tmux, socket, pane)
        client = metadata.get("client", "")
        session_id = metadata.get("session_id", "")
    else:
        client = os.environ.get("AI_AGENT_CLIENT", "")
        session_id = payload.get("session_id") or ""
    if not isinstance(client, str) or not isinstance(session_id, str):
        return 1
    if not client or not session_id:
        return 0
    event = payload.get("hook_event_name", "")
    if not observer and event not in (
        "SessionStart",
        "UserPromptSubmit",
        "Stop",
    ):
        return 0
    cwd = payload.get("cwd") or ""
    if not isinstance(cwd, str):
        return 1
    try:
        if client == "Codex":
            title = codex_title(session_id)
        else:
            title = payload.get("session_title") if not observer else None
            if title is None:
                if not observer:
                    socket = os.environ.get("TMUX", "").rsplit(",", 2)[0]
                    pane = os.environ.get("TMUX_PANE", "")
                    metadata = pane_metadata(tmux, socket, pane)
                if (
                    metadata.get("client") == client
                    and metadata.get("session_id") == session_id
                    and metadata.get("title_known") is True
                ):
                    value = metadata.get("title")
                    if isinstance(value, str):
                        title = value
            if title is not None and not isinstance(title, str):
                return 1
            if title is not None:
                title = title.strip()
            elif observer or event != "SessionStart":
                return 1
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError):
        if observer or event != "SessionStart":
            raise
        title = None
    normalized = application_input(client, session_id, title, cwd)
    if observer:
        print(json.dumps(normalized))
        return 0
    command = [sys.argv[2], "record", "--on-change"]
    if event == "SessionStart":
        command.append("--force")
    timeout = 4.0 - (time.monotonic() - started)
    if timeout <= 0:
        return 1
    return subprocess.run(
        command,
        input=json.dumps(normalized),
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=timeout,
    ).returncode


if __name__ == "__main__":
    try:
        result = main()
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError):
        result = 1
    raise SystemExit(result)
