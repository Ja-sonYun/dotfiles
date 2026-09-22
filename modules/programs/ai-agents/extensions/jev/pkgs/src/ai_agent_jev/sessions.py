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

from ai_agent_jev.rule_files import (
    project_root,
    read_json,
    rule_path,
    rules_directory,
    write_json,
)


@dataclass(frozen=True)
class Session:
    cwd: Path
    root: Path
    last_seen: float

    def record(self) -> dict[str, object]:
        return {
            "cwd": str(self.cwd),
            "root": str(self.root),
            "last_seen": self.last_seen,
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
    cwd, root, last_seen = data.get("cwd"), data.get("root"), data.get("last_seen")
    if (
        not isinstance(cwd, str)
        or not Path(cwd).is_absolute()
        or not isinstance(root, str)
        or not Path(root).is_absolute()
        or not isinstance(last_seen, (int, float))
        or isinstance(last_seen, bool)
    ):
        raise ValueError(f"Invalid session metadata: {path}")
    return Session(Path(cwd), Path(root), float(last_seen))


def delete_session(path: Path, session: Session) -> None:
    directory = rules_directory(session.root, path.stem)
    try:
        entries = list(directory.iterdir())
    except FileNotFoundError:
        entries = []
    for entry in entries:
        if entry.suffix == ".json":
            rule_path(directory, entry.stem).unlink()
    path.unlink()


@contextmanager
def state_lock() -> Iterator[Path]:
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    directory = cache / "ai-agent" / "jev" / "sessions"
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
                    raise TimeoutError("Jev rule storage is busy.") from None
                time.sleep(0.01)
        cutoff = time.time() - 86400
        for path in directory.iterdir():
            if path.suffix != ".json":
                continue
            try:
                session = read_session(session_path(directory, path.stem))
                if session.last_seen < cutoff:
                    delete_session(path, session)
            except (OSError, TypeError, ValueError) as error:
                print(f"[Jev cleanup failed] {path}: {error}", file=sys.stderr)
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
    session = Session(previous.cwd, previous.root, time.time())
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
            root = previous.root
            created = False
        except FileNotFoundError:
            root = project_root(cwd)
            created = True
        write_json(path, Session(cwd, root, time.time()).record())
    return handle, created


def end_session(hook_input: HookInput) -> None:
    handle = session_key(hook_input)
    if handle is not None:
        with state_lock() as directory:
            path = session_path(directory, handle)
            try:
                session = read_session(path)
            except FileNotFoundError:
                return
            delete_session(path, session)
