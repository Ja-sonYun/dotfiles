import fcntl
import hashlib
import json
import os
import re
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from ai_agent_hooks.hook_input import HookInput

from ai_agent_rules.rule_files import read_json, write_json


@dataclass(frozen=True)
class Session:
    cwd: Path
    last_seen: float
    blocked_inputs: frozenset[str] = frozenset()

    def record(self) -> dict[str, object]:
        return {
            "cwd": str(self.cwd),
            "last_seen": self.last_seen,
            "blocked_inputs": sorted(self.blocked_inputs),
        }


def session_key(hook_input: HookInput) -> str | None:
    client = os.environ.get("AI_AGENT_CLIENT", "").lower()
    session = hook_input.get("session_id")
    if not client or not isinstance(session, str) or not session:
        return None
    return hashlib.sha256(json.dumps([client, session]).encode()).hexdigest()


def session_path(directory: Path, handle: str) -> Path:
    if re.fullmatch(r"[0-9a-f]{64}", handle) is None:
        raise ValueError("Use the session_handle supplied by the session hook.")
    return directory / f"{handle}.json"


def read_session(path: Path) -> Session:
    data = read_json(path)
    if not isinstance(data, dict):
        raise TypeError(f"Invalid session metadata: {path}")
    cwd, last_seen = data.get("cwd"), data.get("last_seen")
    blocked_inputs = data.get("blocked_inputs", [])
    if (
        not isinstance(cwd, str)
        or not Path(cwd).is_absolute()
        or not isinstance(last_seen, (int, float))
        or isinstance(last_seen, bool)
        or not isinstance(blocked_inputs, list)
        or any(not isinstance(value, str) for value in blocked_inputs)
    ):
        raise ValueError(f"Invalid session metadata: {path}")
    return Session(Path(cwd), float(last_seen), frozenset(blocked_inputs))


@contextmanager
def state_lock() -> Iterator[Path]:
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    directory = cache / "ai-agent" / "rules" / "sessions"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(
        directory.parent / "state.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600
    )
    with os.fdopen(descriptor, "a") as lock:
        deadline = time.monotonic() + 1
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Rule storage is busy.") from None
                time.sleep(0.01)
        cutoff = time.time() - 86400
        for path in directory.iterdir():
            if path.suffix != ".json":
                continue
            try:
                session = read_session(session_path(directory, path.stem))
                if session.last_seen < cutoff:
                    path.unlink()
            except (OSError, TypeError, ValueError) as error:
                print(f"[Rules cleanup failed] {path}: {error}", file=sys.stderr)
        yield directory


def require_session(directory: Path, handle: str) -> Session:
    path = session_path(directory, handle)
    try:
        previous = read_session(path)
    except FileNotFoundError as error:
        raise ValueError(
            "Unknown or expired session_handle; use the handle from the session hook."
        ) from error
    if previous.last_seen < time.time() - 86400:
        raise ValueError("Expired session_handle; session cleanup is incomplete.")
    session = Session(previous.cwd, time.time(), previous.blocked_inputs)
    write_json(path, session.record())
    return session


def register_session(hook_input: HookInput) -> tuple[str | None, bool]:
    handle = session_key(hook_input)
    if handle is None:
        return None, False
    cwd = Path(str(hook_input.get("cwd") or Path.cwd())).resolve()
    with state_lock() as directory:
        path = session_path(directory, handle)
        try:
            previous = read_session(path)
            if previous.last_seen < time.time() - 86400:
                raise ValueError(
                    "Cannot reuse an expired session before its cleanup completes."
                )
            created = False
        except FileNotFoundError:
            previous = Session(cwd, time.time())
            created = True
        write_json(path, Session(cwd, time.time(), previous.blocked_inputs).record())
    return handle, created


def record_rejection(handle: str, hook_input: HookInput) -> bool:
    """Record this input atomically and report whether it was already rejected."""
    value = [
        str(Path(str(hook_input.get("cwd") or Path.cwd())).resolve()),
        str(hook_input.get("tool_name") or "").rsplit(".", 1)[-1].lower(),
        hook_input.get("tool_input"),
    ]
    digest = hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
    with state_lock() as directory:
        session = require_session(directory, handle)
        if digest in session.blocked_inputs:
            return True
        write_json(
            session_path(directory, handle),
            Session(
                session.cwd, session.last_seen, session.blocked_inputs | {digest}
            ).record(),
        )
    return False


def end_session(hook_input: HookInput) -> None:
    handle = session_key(hook_input)
    if handle is not None:
        with state_lock() as directory:
            path = session_path(directory, handle)
            try:
                read_session(path)
            except FileNotFoundError:
                return
            path.unlink()
