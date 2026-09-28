import hashlib
import json
import os
import re
import sqlite3
from collections.abc import Iterator
from contextlib import closing, contextmanager
from dataclasses import dataclass
from pathlib import Path

from ai_agent_hooks.hook_input import HookInput

from ai_agent_rules.context import environment


@dataclass(frozen=True)
class Session:
    cwd: Path
    client: str


def session_key(hook_input: HookInput) -> str | None:
    client = environment().get("AI_AGENT_CLIENT", "").lower()
    session = hook_input.get("session_id")
    if (
        client not in {"codex", "claude", "pi"}
        or not isinstance(session, str)
        or not session
    ):
        return None
    return hashlib.sha256(json.dumps([client, session]).encode()).hexdigest()


@contextmanager
def state_transaction() -> Iterator[sqlite3.Connection]:
    cache = Path(environment().get("XDG_CACHE_HOME") or Path.home() / ".cache")
    directory = cache / "ai-agent" / "rules"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    path = directory / "sessions.sqlite3"
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)

    try:
        with closing(
            sqlite3.connect(path, timeout=1, isolation_level=None)
        ) as database:
            database.execute("PRAGMA auto_vacuum = FULL")
            database.execute("PRAGMA foreign_keys = ON")
            database.execute("BEGIN IMMEDIATE")
            with database:
                database.execute(
                    "CREATE TABLE IF NOT EXISTS sessions ("
                    "handle TEXT PRIMARY KEY, cwd TEXT NOT NULL, client TEXT NOT NULL)"
                )
                database.execute(
                    "CREATE TABLE IF NOT EXISTS rejections ("
                    "session_handle TEXT NOT NULL REFERENCES sessions(handle) "
                    "ON DELETE CASCADE, input_hash TEXT NOT NULL, "
                    "PRIMARY KEY (session_handle, input_hash))"
                )
                yield database
    except sqlite3.Error as error:
        raise OSError(f"Rule storage is unavailable ({error}).") from error


def require_session(database: sqlite3.Connection, handle: str) -> Session:
    if re.fullmatch(r"[0-9a-f]{64}", handle) is None:
        raise ValueError("Use the session_handle supplied by the session hook.")
    row = database.execute(
        "SELECT cwd, client FROM sessions WHERE handle = ?", (handle,)
    ).fetchone()
    if row is None:
        raise ValueError(
            "Unknown session_handle; use the handle from the session hook."
        )
    return Session(Path(row[0]), row[1])


def register_session(hook_input: HookInput) -> tuple[str | None, bool]:
    handle = session_key(hook_input)
    if handle is None:
        return None, False
    cwd = Path(str(hook_input.get("cwd") or Path.cwd())).resolve()
    client = environment()["AI_AGENT_CLIENT"].lower()
    with state_transaction() as database:
        created = (
            database.execute(
                "INSERT OR IGNORE INTO sessions (handle, cwd, client) VALUES (?, ?, ?)",
                (handle, str(cwd), client),
            ).rowcount
            == 1
        )
        if not created:
            database.execute(
                "UPDATE sessions SET cwd = ?, client = ? WHERE handle = ?",
                (str(cwd), client, handle),
            )
    return handle, created


def record_rejection(handle: str, hook_input: HookInput) -> bool:
    """Record this input atomically and report whether it was already rejected."""
    value = [
        str(Path(str(hook_input.get("cwd") or Path.cwd())).resolve()),
        str(hook_input.get("tool_name") or "").rsplit(".", 1)[-1].lower(),
        hook_input.get("tool_input"),
    ]
    digest = hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
    with state_transaction() as database:
        require_session(database, handle)
        repeated = (
            database.execute(
                "INSERT OR IGNORE INTO rejections (session_handle, input_hash) "
                "VALUES (?, ?)",
                (handle, digest),
            ).rowcount
            == 0
        )
    return repeated


def end_session(hook_input: HookInput) -> None:
    handle = session_key(hook_input)
    if handle is not None:
        with state_transaction() as database:
            database.execute("DELETE FROM sessions WHERE handle = ?", (handle,))


def reset_sessions() -> None:
    with state_transaction() as database:
        database.execute("DELETE FROM sessions")
