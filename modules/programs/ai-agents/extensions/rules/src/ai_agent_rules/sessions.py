import hashlib
import json
import os
import re
import secrets
import sqlite3
from collections.abc import Iterator
from contextlib import closing, contextmanager
from dataclasses import dataclass
from pathlib import Path

from ai_agent_hooks.edit_input import edit_targets
from ai_agent_hooks.hook_input import HookInput, load_hook_input

from ai_agent_rules.context import environment


@dataclass(frozen=True)
class Session:
    cwd: Path
    client: str


@dataclass(frozen=True)
class ApprovalRequest:
    id: str
    session_handle: str
    request: str
    files: str
    feedback: str


def session_key(hook_input: HookInput) -> str | None:
    client = environment().get("AI_AGENT_CLIENT", "").lower()
    session = hook_input.get("session_id")
    if client not in {"codex", "claude"} or not isinstance(session, str) or not session:
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
                    "CREATE TABLE IF NOT EXISTS approval_requests ("
                    "id TEXT PRIMARY KEY, "
                    "session_handle TEXT NOT NULL REFERENCES sessions(handle) "
                    "ON DELETE CASCADE, input_hash TEXT NOT NULL, "
                    "request TEXT NOT NULL, files TEXT NOT NULL, feedback TEXT NOT NULL, "
                    "status TEXT NOT NULL DEFAULT 'pending', "
                    "approved_at TEXT, consumed_at TEXT)"
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


def request_identity(request: HookInput) -> tuple[str, str]:
    value = json.dumps(
        {
            "kind": request.get("kind", "tool"),
            "cwd": str(Path(str(request.get("cwd") or Path.cwd())).resolve()),
            "tool_name": str(request.get("tool_name") or ""),
            "tool_input": request.get("tool_input"),
        },
        sort_keys=True,
    )
    return hashlib.sha256(value.encode()).hexdigest(), value


def file_state(request: HookInput) -> str:
    files = {}
    for target in edit_targets(request, resolve_paths=False):
        for path in (target.before, target.after):
            resolved = path.resolve()
            try:
                with resolved.open("rb") as source:
                    content = hashlib.file_digest(source, "sha256").hexdigest()
                    mode = os.fstat(source.fileno()).st_mode
            except FileNotFoundError:
                content, mode = None, None
            files[str(path)] = [str(resolved), content, mode]
    return json.dumps(files, sort_keys=True)


def pending_approval(handle: str, request_id: str) -> ApprovalRequest:
    with state_transaction() as database:
        require_session(database, handle)
        row = database.execute(
            "SELECT request, files, feedback, status FROM approval_requests "
            "WHERE id = ? AND session_handle = ?",
            (request_id, handle),
        ).fetchone()
        if row is None:
            raise ValueError("Unknown request ID for this session.")
        if row[3] != "pending":
            raise ValueError(f"Request is already {row[3]}.")
        if file_state(load_hook_input(row[0])) != row[1]:
            raise ValueError("Files changed since rejection; submit the request again.")
    return ApprovalRequest(request_id, handle, row[0], row[1], row[2])


def approve_request(approval: ApprovalRequest) -> None:
    with state_transaction() as database:
        require_session(database, approval.session_handle)
        if file_state(load_hook_input(approval.request)) != approval.files:
            raise ValueError("Files changed while reviewing; submit the request again.")
        changed = database.execute(
            "UPDATE approval_requests SET status = 'approved', "
            "approved_at = CURRENT_TIMESTAMP "
            "WHERE id = ? AND session_handle = ? AND status = 'pending' "
            "AND request = ? AND files = ? AND feedback = ?",
            (
                approval.id,
                approval.session_handle,
                approval.request,
                approval.files,
                approval.feedback,
            ),
        ).rowcount
        if changed != 1:
            raise ValueError("Request changed, expired, or was already handled.")


def record_rejection(handle: str, request: HookInput, feedback: str) -> str:
    digest, value = request_identity(request)
    files = file_state(request)
    with state_transaction() as database:
        require_session(database, handle)
        row = database.execute(
            "SELECT id FROM approval_requests WHERE session_handle = ? "
            "AND input_hash = ? AND files = ? AND status = 'pending'",
            (handle, digest, files),
        ).fetchone()
        if row is not None:
            database.execute(
                "UPDATE approval_requests SET feedback = ? WHERE id = ?",
                (feedback, row[0]),
            )
            return str(row[0])
        request_id = secrets.token_hex(16)
        database.execute(
            "INSERT INTO approval_requests "
            "(id, session_handle, input_hash, request, files, feedback) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (request_id, handle, digest, value, files, feedback),
        )
    return request_id


def consume_approval(handle: str, request: HookInput) -> str | None:
    digest, _ = request_identity(request)
    with state_transaction() as database:
        require_session(database, handle)
        row = database.execute(
            "SELECT id, files FROM approval_requests WHERE session_handle = ? "
            "AND input_hash = ? AND status = 'approved'",
            (handle, digest),
        ).fetchone()
        if row is None:
            return None
        if row[1] != file_state(request):
            database.execute(
                "UPDATE approval_requests SET status = 'stale' WHERE id = ?",
                (row[0],),
            )
            return None
        database.execute(
            "UPDATE approval_requests SET status = 'consumed', "
            "consumed_at = CURRENT_TIMESTAMP WHERE id = ?",
            (row[0],),
        )
    return str(row[0])


def end_session(hook_input: HookInput) -> None:
    handle = session_key(hook_input)
    if handle is not None:
        with state_transaction() as database:
            database.execute("DELETE FROM sessions WHERE handle = ?", (handle,))
