from __future__ import annotations

import argparse
import asyncio
import fcntl
import json
import os
import select
import signal
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

import httpx
import psutil

from ai_agent_rules.context import HookContext, current
from ai_agent_rules.hooks import process_event
from ai_agent_rules.sessions import reset_sessions

Owner = tuple[int, float]
SessionKey = tuple[str, str, Owner]
MAX_LOG_BYTES = 5 * 1024 * 1024


def write_log(directory: Path, record: dict[str, object]) -> None:
    data = (json.dumps(record, ensure_ascii=False) + "\n").encode()
    if len(data) > MAX_LOG_BYTES:
        data = (
            json.dumps(
                {
                    "time": record["time"],
                    "pid": record["pid"],
                    "event": "log_record_too_large",
                    "request_id": record.get("request_id"),
                    "bytes": len(data),
                }
            )
            + "\n"
        ).encode()
    try:
        descriptor = os.open(
            directory / "server.log.lock",
            os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(descriptor, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = directory / "server.log"
            if path.exists() and path.stat().st_size + len(data) > MAX_LOG_BYTES:
                path.replace(directory / "server.log.1")
            # Reopen under the shared lock to follow rotations by other servers.
            descriptor = os.open(
                path, os.O_CREAT | os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW, 0o600
            )
            with os.fdopen(descriptor, "ab") as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(data)
    except OSError:
        try:
            print("[Rules log] Cannot write server log.", file=sys.stderr)
        except OSError:
            pass


def reset_database(directory: Path, configuration: str, reason: str) -> None:
    """Log each reset, aborting startup but allowing shutdown on storage failure."""
    error_type: str | None = None
    try:
        reset_sessions()
    except OSError as error:
        error_type = type(error).__name__
        if reason == "startup":
            raise
    finally:
        write_log(
            directory,
            {
                "time": datetime.now(UTC).isoformat(timespec="milliseconds"),
                "pid": os.getpid(),
                "configuration": configuration,
                "event": "database_reset",
                "reason": reason,
                "success": error_type is None,
                "error_type": error_type,
            },
        )


@contextmanager
def server_lifetime(directory: Path, configuration: str) -> Iterator[None]:
    """Reset shared state only at the first startup and last shutdown."""
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    with (
        os.fdopen(os.open(directory / "lifecycle.lock", flags, 0o600), "a") as gate,
        os.fdopen(os.open(directory / "active.lock", flags, 0o600), "a") as active,
    ):
        fcntl.flock(gate, fcntl.LOCK_EX)
        joined = False
        try:
            try:
                fcntl.flock(active, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                reset_database(directory, configuration, "startup")
            fcntl.flock(active, fcntl.LOCK_SH)
            joined = True
        finally:
            if not joined:
                fcntl.flock(active, fcntl.LOCK_UN)
            fcntl.flock(gate, fcntl.LOCK_UN)

        try:
            yield
        finally:
            fcntl.flock(gate, fcntl.LOCK_EX)
            try:
                fcntl.flock(active, fcntl.LOCK_UN)
                try:
                    fcntl.flock(active, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    reset_database(directory, configuration, "shutdown")
            finally:
                fcntl.flock(active, fcntl.LOCK_UN)
                fcntl.flock(gate, fcntl.LOCK_UN)


def detach_stderr() -> None:
    # Release the hook's stderr pipe once startup diagnostics are complete.
    sys.stderr.flush()
    with open(os.devnull, "w") as sink:
        os.dup2(sink.fileno(), 2)


def find_owner(pid: int, client: str) -> psutil.Process:
    try:
        child = psutil.Process(pid)
        while True:
            parent_pid = child.ppid()
            if parent_pid == 0 or parent_pid == child.pid:
                break
            process = psutil.Process(parent_pid)
            if process.create_time() > child.create_time():
                break
            child = process
            if process.uids().real != os.getuid() or not process.is_running():
                continue
            command_line = process.cmdline()
            names = [process.name(), *command_line[:1]]
            for name in names:
                executable = (
                    Path(name).name.lstrip(".").removesuffix("-wrapped").lower()
                )
                matches = (
                    executable
                    == {"Codex": "codex", "Claude": "claude", "Pi": "pi"}[client]
                )
                if executable == "node" and len(command_line) > 1:
                    matches = (
                        client == "Claude"
                        and "/@anthropic-ai/claude-code/" in command_line[1]
                    ) or (client == "Pi" and "/pi-coding-agent/" in command_line[1])
                if matches and process.status() != psutil.STATUS_ZOMBIE:
                    return process
    except psutil.NoSuchProcess as error:
        raise ValueError(
            "A process exited while identifying the calling agent."
        ) from error
    except (psutil.AccessDenied, PermissionError) as error:
        raise ValueError(
            "Cannot inspect the calling agent's parent process."
        ) from error
    raise ValueError("Cannot identify the calling agent process.")


def watch_owner(process: psutil.Process) -> tuple[int, select.kqueue | None]:
    if sys.platform == "darwin":
        queue = select.kqueue()
        try:
            queue.control(
                [
                    select.kevent(
                        process.pid,
                        filter=select.KQ_FILTER_PROC,
                        flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                        fflags=select.KQ_NOTE_EXIT,
                    )
                ],
                0,
            )
        except OSError:
            queue.close()
            raise
        return queue.fileno(), queue
    return os.pidfd_open(process.pid), None


@dataclass
class Session:
    key: SessionKey
    closing: bool = False


class Server:
    def __init__(self, rules: Path, configuration: str, debug_log: bool) -> None:
        self.rules = rules
        self.configuration = configuration
        self.debug_log = debug_log
        self.owners: dict[Owner, tuple[int, select.kqueue | None]] = {}
        self.sessions: dict[SessionKey, Session] = {}
        self.requests: dict[asyncio.Task[None], Session | None] = {}
        self.stopped = asyncio.Event()
        self.stop_reason = "shutdown"
        self.log_queue: asyncio.Queue[dict[str, object] | None] = asyncio.Queue()

    def record(self, event: str, **fields: object) -> None:
        self.log_queue.put_nowait(
            {
                "time": datetime.now(UTC).isoformat(timespec="milliseconds"),
                "pid": os.getpid(),
                "configuration": self.configuration,
                "event": event,
                **fields,
            }
        )

    async def write_logs(self, directory: Path) -> None:
        while (record := await self.log_queue.get()) is not None:
            await asyncio.to_thread(write_log, directory, record)

    def stop(self, reason: str) -> None:
        if not self.stopped.is_set():
            self.stop_reason = reason
            self.stopped.set()

    async def register(
        self, pid: int, client: str, session_id: str, start: bool
    ) -> Session:
        process = await asyncio.to_thread(find_owner, pid, client)
        owner = (process.pid, process.create_time())
        key = (client, session_id, owner)
        session = self.sessions.get(key)
        if not start:
            if session is None or session.closing:
                raise ValueError("The rules session is not registered.")
            return session
        if owner not in self.owners:
            descriptor, queue = watch_owner(process)
            try:
                if (
                    not process.is_running()
                    or psutil.Process(process.pid).create_time() != owner[1]
                ):
                    raise ProcessLookupError("The calling agent has exited.")
                asyncio.get_running_loop().add_reader(
                    descriptor, self.owner_exited, owner
                )
            except (OSError, psutil.Error):
                if queue is None:
                    os.close(descriptor)
                else:
                    queue.close()
                raise
            self.owners[owner] = (descriptor, queue)
        if session is None or session.closing:
            session = Session(key)
            self.sessions[key] = session
            self.record(
                "session_registered",
                client=client,
                session_id=session_id,
                owner_pid=owner[0],
                owner_created=owner[1],
            )
        return session

    def remove_watch(self, owner: Owner) -> None:
        watch = self.owners.pop(owner, None)
        if watch is None:
            return
        descriptor, queue = watch
        asyncio.get_running_loop().remove_reader(descriptor)
        if queue is None:
            os.close(descriptor)
        else:
            queue.close()

    def owner_exited(self, owner: Owner) -> None:
        self.record("owner_exited", owner_pid=owner[0], owner_created=owner[1])
        self.remove_watch(owner)
        for key in tuple(self.sessions):
            if key[2] == owner:
                del self.sessions[key]
                self.record(
                    "session_removed",
                    client=key[0],
                    session_id=key[1],
                    owner_pid=owner[0],
                    reason="owner_exited",
                )
        for task, session in tuple(self.requests.items()):
            if (
                session is not None
                and session.key[2] == owner
                and not task.cancelling()
            ):
                task.cancel()
        self.stop_if_unused()

    def stop_if_unused(self) -> None:
        active = {key[2] for key in self.sessions}
        active.update(
            session.key[2] for session in self.requests.values() if session is not None
        )
        for owner in tuple(self.owners):
            if owner not in active:
                self.remove_watch(owner)
        if not self.sessions and not self.requests:
            self.stop("no_active_sessions")

    async def execute(
        self,
        request: dict[str, object],
        hook_input: dict[str, object],
        api: httpx.AsyncClient,
        evaluations: list[dict[str, object]],
    ) -> HookContext:
        environment = request["environment"]
        if not isinstance(environment, dict) or any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in environment.items()
        ):
            raise TypeError("Invalid hook environment.")
        environment = {**environment, "AI_AGENT_CLIENT": str(request["client"])}
        environment["PATH"] = (
            os.environ.get("PATH", "") + os.pathsep + environment.get("PATH", "")
        )
        budget = min(
            float(request["timeout"]),
            float(request["started"]) + float(request["timeout"]) - time.time(),
        )
        if budget <= 0:
            raise TimeoutError("Hook deadline expired.")
        context = HookContext(
            environment, time.monotonic() + budget, evaluations=evaluations
        )
        token = current.set(context)
        try:
            async with asyncio.timeout(budget):
                await process_event(hook_input, self.rules, api, self.debug_log)
            return context
        finally:
            current.reset(token)

    async def handle(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        api: httpx.AsyncClient,
    ) -> None:
        task = asyncio.current_task()
        if task is None:
            writer.close()
            return
        self.requests[task] = None
        session: Session | None = None
        ending = False
        work: asyncio.Task[HookContext] | None = None
        disconnected: asyncio.Task[bytes] | None = None
        response = {"stdout": "", "stderr": "", "exit_code": 0}
        request_id = uuid4().hex
        started = time.monotonic()
        evaluations: list[dict[str, object]] = []
        details: dict[str, object] = {"request_id": request_id}
        status = "empty_request"
        stage = "read_request"
        error_type: str | None = None
        response_sent = False
        rules_decision: str | None = None
        self.record("request_received", request_id=request_id)
        try:
            raw = await asyncio.wait_for(reader.readline(), 5)
            if not raw:
                return
            request = json.loads(raw)
            stage = "validate_request"
            if (
                not isinstance(request, dict)
                or request.get("configuration") != self.configuration
            ):
                raise ValueError("Rules server configuration does not match.")
            if self.stopped.is_set():
                response["retry_registration"] = True
                status = "retry_registration"
                return
            hook_input = request["input"]
            if not isinstance(hook_input, dict):
                raise TypeError("Hook input must be an object.")
            session_id = hook_input.get("session_id")
            event = hook_input.get("hook_event_name")
            if not isinstance(session_id, str) or not session_id:
                raise ValueError("Missing session ID.")
            if event not in {"SessionStart", "SessionEnd", "PreToolUse", "PostToolUse"}:
                raise ValueError("Unsupported rules hook event.")
            registering = request.get("register_only") is True
            details.update(
                client=request.get("client")
                if request.get("client") in ("Codex", "Claude", "Pi")
                else None,
                session_id=session_id,
                hook_event=event,
                tool_name=hook_input.get("tool_name")
                if isinstance(hook_input.get("tool_name"), str)
                else None,
                register_only=registering,
            )
            if registering and event == "SessionEnd":
                raise ValueError("Cannot register a session during shutdown.")
            stage = "register_session"
            session = await self.register(
                int(request["pid"]),
                str(request["client"]),
                session_id,
                registering,
            )
            self.requests[task] = session
            details["owner_pid"] = session.key[2][0]
            if registering:
                response["registered"] = True
                status = "registered"
                return
            ending = event == "SessionEnd"
            if ending:
                session.closing = True
            stage = "execute_hook"
            work = asyncio.create_task(
                self.execute(request, hook_input, api, evaluations)
            )
            disconnected = asyncio.create_task(reader.read(1))
            done, _ = await asyncio.wait(
                (work, disconnected), return_when=asyncio.FIRST_COMPLETED
            )
            if disconnected in done:
                status = "disconnected"
                return
            context = await work
            rules_decision = context.rules_decision
            response["stdout"] = "".join(context.stdout)
            response["stderr"] = (
                "".join(context.stderr)
                .encode()[:65536]
                .decode("utf-8", errors="ignore")
            )
            status = "completed"
        except asyncio.CancelledError:
            status = "cancelled"
            raise
        except (
            OSError,
            ValueError,
            TypeError,
            KeyError,
            RuntimeError,
            psutil.Error,
        ) as error:
            status = "failed"
            error_type = type(error).__name__
            response["stderr"] = (
                "[Rules not checked] Rules server request failed; continuing.\n"
            )
        finally:
            for child in (work, disconnected):
                if child is not None and not child.done():
                    child.cancel()
            await asyncio.gather(
                *(child for child in (work, disconnected) if child is not None),
                return_exceptions=True,
            )
            if not writer.is_closing() and not task.cancelling():
                try:
                    writer.write(
                        (json.dumps(response, ensure_ascii=False) + "\n").encode()
                    )
                    await writer.drain()
                    response_sent = True
                except (ConnectionError, OSError) as error:
                    details["delivery_error_type"] = type(error).__name__
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass
            finally:
                self.record(
                    "request_completed",
                    **details,
                    status=status,
                    stage=stage,
                    error_type=error_type,
                    elapsed_ms=round((time.monotonic() - started) * 1000, 3),
                    response_sent=response_sent,
                    stdout_present=bool(response["stdout"]),
                    stderr_present=bool(response["stderr"]),
                    exit_code=response["exit_code"],
                    evaluations=evaluations,
                    rules_decision=rules_decision,
                )
                if (
                    ending
                    and session is not None
                    and self.sessions.get(session.key) is session
                ):
                    del self.sessions[session.key]
                    self.record(
                        "session_removed",
                        client=session.key[0],
                        session_id=session.key[1],
                        owner_pid=session.key[2][0],
                        reason="session_end",
                    )
                self.requests.pop(task, None)
                self.stop_if_unused()

    async def serve(
        self, directory: Path, parent: int, client: str, session_id: str
    ) -> None:
        log_task = asyncio.create_task(self.write_logs(directory.parent))
        self.record("server_starting", client=client, session_id=session_id)
        stage = "register_session"
        try:
            await self.register(parent, client, session_id, True)
            loop = asyncio.get_running_loop()
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                loop.add_signal_handler(signum, self.stop, f"signal:{signum.name}")
            stage = "listen"
            async with httpx.AsyncClient(follow_redirects=False) as api:
                server = await asyncio.start_unix_server(
                    lambda reader, writer: self.handle(reader, writer, api),
                    path=directory / "server.sock",
                    limit=16 * 1024 * 1024,
                    start_serving=False,
                )
                (directory / "server.sock").chmod(0o600)
                (directory / "server.pid").write_text(f"{os.getpid()}\n")
                try:
                    await asyncio.to_thread(detach_stderr)
                    await server.start_serving()
                    stage = "serve"
                    self.record("server_ready")
                    await self.stopped.wait()
                finally:
                    server.close()
                    await server.wait_closed()
                    for task in tuple(self.requests):
                        if not task.cancelling():
                            task.cancel()
                    await asyncio.gather(*tuple(self.requests), return_exceptions=True)
                    for owner in tuple(self.owners):
                        self.remove_watch(owner)
        except asyncio.CancelledError:
            self.stop_reason = "cancelled"
            raise
        except Exception as error:
            self.stop_reason = "failed"
            self.record("server_error", stage=stage, error_type=type(error).__name__)
            raise
        finally:
            self.record("server_stopped", reason=self.stop_reason)
            self.log_queue.put_nowait(None)
            await log_task


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rules", type=Path, required=True)
    parser.add_argument("--debug-log", action="store_true")
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--parent", type=int, required=True)
    parser.add_argument("--client", choices=("Codex", "Claude", "Pi"), required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--configuration", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    args.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.directory.chmod(0o700)
    descriptor = os.open(
        args.directory / "server.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600
    )
    with os.fdopen(descriptor, "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        (args.directory / "server.sock").unlink(missing_ok=True)
        (args.directory / "server.pid").unlink(missing_ok=True)
        # Keep the lease until asyncio.run has also drained its worker threads.
        with server_lifetime(args.directory.parent, args.configuration):
            try:
                asyncio.run(
                    Server(args.rules, args.configuration, args.debug_log).serve(
                        args.directory, args.parent, args.client, args.session
                    )
                )
            finally:
                (args.directory / "server.sock").unlink(missing_ok=True)
                (args.directory / "server.pid").unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
