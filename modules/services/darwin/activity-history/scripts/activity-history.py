import argparse
import fcntl
import gzip
import json
import os
import shutil
import stat
import subprocess
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import date, datetime, time as wall_time, timedelta, timezone
from pathlib import Path
from typing import Annotated, Any, Literal, Self
from uuid import uuid4

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    NonNegativeFloat,
    NonNegativeInt,
    PositiveInt,
    TypeAdapter,
    ValidationError,
)
from pydantic.alias_generators import to_camel
from pydantic_settings import (
    BaseSettings,
    JsonConfigSettingsSource,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
)


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True)


class CaptureSettings(Model):
    model_config = ConfigDict(alias_generator=to_camel)
    interval_seconds: PositiveInt
    debounce_milliseconds: PositiveInt
    idle_threshold_seconds: PositiveInt
    on_context_change: bool
    on_click: bool
    on_enter: bool


class IntegrationSettings(Model):
    enable: bool


class Integrations(Model):
    tmux: IntegrationSettings
    zsh: IntegrationSettings


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        alias_generator=to_camel, extra="forbid", hide_input_in_errors=True
    )
    data_directory: Path
    state_directory: Path
    start_paused: bool
    capture: CaptureSettings
    integrations: Integrations
    excluded_apps: list[str]
    tmux: Path
    event_observers: list[list[str]] = Field(default_factory=list)

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        return (init_settings,)

    @classmethod
    def from_file(cls, path: Path) -> Self:
        source = JsonConfigSettingsSource(
            cls, json_file=path, json_file_encoding="utf-8"
        )
        return cls(**source())


class CollectorState(Model):
    run_id: str
    pid: PositiveInt
    running: bool
    recording: bool
    allowed: bool
    reason: str
    excluded_apps: list[str]
    accept_since: NonNegativeFloat
    heartbeat: NonNegativeFloat
    terminal_front: bool
    error: str | None = None


class EventBase(Model):
    schema_version: Literal[1] = 1
    event_id: str = Field(default_factory=lambda: str(uuid4()))
    at: str
    collector_run_id: str


class ContextChange(EventBase):
    type: Literal["context_change"] = "context_change"
    source: Literal["hammerspoon"] = "hammerspoon"
    context_id: str
    app_id: str
    app_name: str
    pid: PositiveInt
    window_id: NonNegativeInt
    window_title: str


class ContextUpdate(EventBase):
    type: Literal["context_update"] = "context_update"
    source: Literal["hammerspoon"] = "hammerspoon"
    context_id: str
    window_title: str


class AppLifecycle(EventBase):
    type: Literal["app_launched", "app_terminated"]
    source: Literal["hammerspoon"] = "hammerspoon"
    app_id: str
    app_name: str
    pid: PositiveInt


class WindowLifecycle(EventBase):
    type: Literal[
        "window_created",
        "window_destroyed",
        "window_minimized",
        "window_unminimized",
        "window_fullscreened",
        "window_unfullscreened",
    ]
    source: Literal["hammerspoon"] = "hammerspoon"
    app_id: str
    app_name: str
    pid: PositiveInt
    window_id: PositiveInt
    window_title: str


class IdleState(EventBase):
    type: Literal["idle_state"] = "idle_state"
    source: Literal["hammerspoon"] = "hammerspoon"
    state: Literal["idle", "active"]
    idle_seconds: NonNegativeFloat
    threshold_seconds: PositiveInt


class TextSnapshot(EventBase):
    type: Literal["text_snapshot"] = "text_snapshot"
    source: Literal["hammerspoon"] = "hammerspoon"
    context_id: str
    trigger: str
    text: str
    text_hash: str
    result: Literal["text_found", "unavailable", "error"]
    nodes: NonNegativeInt
    calls: NonNegativeInt
    read_errors: NonNegativeInt
    partial: bool
    ax_seconds: NonNegativeFloat
    cpu_seconds: NonNegativeFloat
    viewport_filtered: bool
    focus_role: str | None = None
    limit: str | None = None
    depth_limited: bool | None = None


class LocationSnapshot(EventBase):
    type: Literal["location_snapshot"] = "location_snapshot"
    source: Literal["hammerspoon"] = "hammerspoon"
    context_id: str
    trigger: str
    location: dict[str, Any]
    summary: str
    result: Literal["found", "unavailable", "error"]
    partial: bool
    missing_fields: list[str] = Field(default_factory=list)
    calls: NonNegativeInt
    nodes: NonNegativeInt
    read_errors: NonNegativeInt
    ax_seconds: NonNegativeFloat
    cpu_seconds: NonNegativeFloat
    discovery_limited: bool
    limit: str | None = None


class RecordingState(EventBase):
    type: Literal["recording_state"] = "recording_state"
    source: Literal["hammerspoon"] = "hammerspoon"
    reason: str
    recording: bool | None = None
    pid: PositiveInt | None = None
    original: bool | None = None
    request_accepted: bool | None = None
    restoration_verified: bool | None = None


class TerminalFields(Model):
    tmux_socket: str
    client_tty: str
    session_id: str
    window_id: str
    pane_id: str
    command: str
    cwd: str
    session_name: str = ""
    pane_title: str = ""


class TerminalContext(EventBase, TerminalFields):
    type: Literal["terminal_context"] = "terminal_context"
    source: Literal["tmux"] = "tmux"
    reason: str


class TmuxLifecycle(EventBase):
    type: Literal["tmux_lifecycle"] = "tmux_lifecycle"
    source: Literal["tmux"] = "tmux"
    event_name: Literal[
        "client-attached", "client-detached", "session-created", "session-closed"
    ]
    tmux_socket: str
    server_pid: PositiveInt
    server_started_at: NonNegativeInt
    client_tty: str
    session_id: str
    session_name: str
    trigger: str | None = None


class ApplicationInput(Model):
    app: str = Field(min_length=1)
    event: str = Field(min_length=1)
    session_id: str = ""
    title: str | None = ""
    cwd: str = ""


class ApplicationActivity(EventBase, TerminalFields):
    type: Literal["application_activity"] = "application_activity"
    source: Literal["application"] = "application"
    app_name: str = Field(min_length=1)
    event_name: str = Field(min_length=1)
    app_session_id: str = ""
    app_title: str = ""


class CommandEvent(EventBase):
    source: Literal["zsh"] = "zsh"
    shell_session_id: str = Field(pattern=r"^[0-9-]+$")
    command_id: str
    cwd: str


class CommandStart(CommandEvent):
    type: Literal["command_start"] = "command_start"
    command: str
    tty: str
    tmux_socket: str
    pane_id: str


class CommandEnd(CommandEvent):
    type: Literal["command_end"] = "command_end"
    exit_code: int
    duration_seconds: NonNegativeFloat


class ShellSession(EventBase):
    type: Literal["shell_session_start", "shell_session_end"]
    source: Literal["zsh"] = "zsh"
    shell_session_id: str = Field(pattern=r"^[0-9-]+$")
    pid: PositiveInt
    tty: str
    cwd: str
    tmux_socket: str
    pane_id: str
    exit_code: int | None = None


Event = Annotated[
    ContextChange
    | ContextUpdate
    | AppLifecycle
    | WindowLifecycle
    | IdleState
    | TextSnapshot
    | LocationSnapshot
    | RecordingState
    | TerminalContext
    | TmuxLifecycle
    | ApplicationActivity
    | CommandStart
    | CommandEnd
    | ShellSession,
    Field(discriminator="type"),
]
EVENTS = TypeAdapter(Event)


class TmuxIdentity(Model):
    context: TerminalFields
    run_id: str
    accept_since: NonNegativeFloat
    day: date


class TmuxCache(Model):
    servers: dict[str, dict[str, TmuxIdentity]] = Field(default_factory=dict)


class TmuxClientSession(Model):
    server_pid: PositiveInt
    server_started_at: NonNegativeInt
    run_id: str
    accept_since: NonNegativeFloat
    session_id: str
    session_name: str


class TmuxClientCache(Model):
    clients: dict[str, TmuxClientSession] = Field(default_factory=dict)


class ApplicationIdentity(Model):
    session_id: str
    title: str
    run_id: str
    accept_since: NonNegativeFloat
    day: date


class ApplicationCache(Model):
    contexts: dict[str, ApplicationIdentity] = Field(default_factory=dict)
    active_panes: dict[str, str] = Field(default_factory=dict)
    pending_contexts: set[str] = Field(default_factory=set)


@contextmanager
def application_cache(config: Settings) -> Iterator[ApplicationCache]:
    path = config.state_directory / "applications.json"
    with path.open("a+", encoding="utf-8") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        try:
            cache = ApplicationCache.model_validate_json(stream.read() or "{}")
        except ValidationError:
            cache = ApplicationCache()
        yield cache
        stream.seek(0)
        stream.truncate()
        stream.write(cache.model_dump_json())


def timestamp(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat(
        timespec="milliseconds"
    )


def day_directory(config: Settings, epoch: float) -> Path:
    return config.data_directory / datetime.fromtimestamp(epoch).date().isoformat()


def state_path(config: Settings) -> Path:
    return config.state_directory / "state.json"


def load_state(config: Settings) -> CollectorState | None:
    try:
        return CollectorState.model_validate_json(
            state_path(config).read_text(encoding="utf-8")
        )
    except (OSError, ValidationError):
        return None


def recording_state(config: Settings) -> CollectorState | None:
    state = load_state(config)
    if state is None:
        return None
    try:
        os.kill(state.pid, 0)
    except OSError:
        return None
    fresh = time.time() - state.heartbeat < max(90, config.capture.interval_seconds * 3)
    return state if state.running and state.allowed and fresh else None


def prepare(config: Settings) -> None:
    for directory in (config.data_directory, config.state_directory):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory.chmod(0o700)
    directory = day_directory(config, time.time())
    directory.mkdir(mode=0o700, exist_ok=True)
    directory.chmod(0o700)
    activity = directory / f"activity-{uuid4()}.jsonl"
    with day_lock(directory):
        for path in (activity, state_path(config)):
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
            os.close(descriptor)
            path.chmod(0o600)
        active_day = config.state_directory / "active-day"
        temporary = active_day.with_suffix(".tmp")
        temporary.write_text(directory.name, encoding="utf-8")
        os.replace(temporary, active_day)
    print(json.dumps({"activityPath": str(activity), "activityDay": directory.name}))


@contextmanager
def day_lock(directory: Path, shared: bool = False) -> Iterator[None]:
    with (directory / ".history.lock").open("r" if shared else "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
        yield


def sync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def replace_gzip(source: Path, destination: Path, extra: bytes = b"") -> None:
    temporary = destination.with_suffix(".gz.tmp")
    try:
        with temporary.open("wb") as output:
            os.fchmod(output.fileno(), stat.S_IMODE(source.stat().st_mode))
            with gzip.GzipFile(
                filename="", mode="wb", compresslevel=9, fileobj=output, mtime=0
            ) as compressed:
                reader = (
                    gzip.open(source, "rb")
                    if source.suffix == ".gz"
                    else source.open("rb")
                )
                with reader:
                    shutil.copyfileobj(reader, compressed)
                compressed.write(extra)
            output.flush()
            fcntl.fcntl(output.fileno(), fcntl.F_FULLFSYNC)
            os.replace(temporary, destination)
            sync_directory(destination.parent)
            fcntl.fcntl(output.fileno(), fcntl.F_FULLFSYNC)
    finally:
        temporary.unlink(missing_ok=True)


def archive(config: Settings, before: date) -> None:
    failed = False
    with (config.state_directory / "archive.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for directory in sorted(config.data_directory.iterdir()):
            if not directory.is_dir():
                continue
            try:
                day = date.fromisoformat(directory.name)
            except ValueError:
                continue
            if directory.name != day.isoformat() or day >= before:
                continue
            try:
                with day_lock(directory):
                    active_day = (config.state_directory / "active-day").read_text(
                        encoding="utf-8"
                    )
                    if directory.name == active_day:
                        continue
                    for source in sorted(directory.glob("*.jsonl")):
                        destination = source.with_suffix(".jsonl.gz")
                        if not destination.exists():
                            replace_gzip(source, destination)
                        with destination.open("rb") as compressed:
                            sync_directory(directory)
                            fcntl.fcntl(compressed.fileno(), fcntl.F_FULLFSYNC)
                            source.unlink()
                            sync_directory(directory)
                            fcntl.fcntl(compressed.fileno(), fcntl.F_FULLFSYNC)
                    for temporary in directory.glob("*.jsonl.gz.tmp"):
                        temporary.unlink()
            except (OSError, EOFError) as error:
                failed = True
                print(
                    f"activity-history: archive {directory}: {error}", file=sys.stderr
                )
    if failed:
        raise OSError("Some activity history files could not be archived")


def append_event(config: Settings, filename: str, event: Event, epoch: float) -> bool:
    directory = day_directory(config, epoch)
    directory.mkdir(mode=0o700, exist_ok=True)
    with day_lock(directory):
        state = recording_state(config)
        if state is None or state.run_id != event.collector_run_id:
            return False
        if epoch < state.accept_since:
            return False
        line = event.model_dump_json(exclude_none=True) + "\n"
        path = directory / filename
        compressed = path.with_suffix(".jsonl.gz")
        if compressed.exists():
            replace_gzip(compressed, compressed, line.encode("utf-8"))
        else:
            with path.open("a", encoding="utf-8") as stream:
                stream.write(line)
    return True


def record_shell(config: Settings, args: argparse.Namespace) -> None:
    if not config.integrations.zsh.enable:
        return
    state = recording_state(config)
    if state is None or args.started < state.accept_since:
        return
    common = {
        "collector_run_id": state.run_id,
        "shell_session_id": args.session,
        "command_id": args.command_id,
        "cwd": args.cwd,
    }
    event: CommandStart | CommandEnd
    if args.action == "_shell-start":
        command = sys.stdin.read()
        if not command or command.startswith(" "):
            return
        epoch = args.started
        event = CommandStart(
            **common,
            at=timestamp(epoch),
            command=command,
            tty=args.tty,
            tmux_socket=args.socket,
            pane_id=args.pane,
        )
    else:
        epoch = args.ended
        event = CommandEnd(
            **common,
            at=timestamp(epoch),
            exit_code=args.exit_code,
            duration_seconds=max(0, epoch - args.started),
        )
    append_event(config, f"shell-{event.shell_session_id}.jsonl", event, epoch)


def record_shell_session(config: Settings, args: argparse.Namespace) -> None:
    if not config.integrations.zsh.enable:
        return
    state = recording_state(config)
    if state is None or args.at < state.accept_since:
        return
    ending = args.action == "_shell-session-end"
    filename = f"shell-{args.session}.jsonl"
    event = ShellSession(
        type="shell_session_end" if ending else "shell_session_start",
        at=timestamp(args.at),
        collector_run_id=state.run_id,
        shell_session_id=args.session,
        pid=args.pid,
        tty=args.tty,
        cwd=args.cwd,
        tmux_socket=args.socket,
        pane_id=args.pane,
        exit_code=args.exit_code,
    )
    if ending and args.command_id and args.started >= state.accept_since:
        command = CommandEnd(
            at=event.at,
            collector_run_id=state.run_id,
            shell_session_id=args.session,
            command_id=args.command_id,
            cwd=args.cwd,
            exit_code=args.exit_code,
            duration_seconds=max(0, args.at - args.started),
        )
        append_event(config, filename, command, args.at)
    append_event(config, filename, event, args.at)


def tmux_output(config: Settings, socket: str, *arguments: str) -> str:
    return subprocess.run(
        [config.tmux, "-S", socket, *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        encoding="utf-8",
        errors="replace",
        timeout=2,
    ).stdout


def append_application(
    config: Settings,
    event: ApplicationActivity,
    state: CollectorState,
    epoch: float,
    cache: ApplicationCache | None = None,
    force: bool = False,
) -> bool:
    key = json.dumps(
        [
            event.app_name,
            event.event_name,
            event.tmux_socket,
            event.pane_id or event.cwd,
        ]
    )
    identity = ApplicationIdentity(
        session_id=event.app_session_id,
        title=event.app_title,
        run_id=state.run_id,
        accept_since=state.accept_since,
        day=datetime.fromtimestamp(epoch).date(),
    )
    if (
        cache is not None
        and not force
        and key not in cache.pending_contexts
        and cache.contexts.get(key) == identity
    ):
        return True
    if not append_event(config, "applications.jsonl", event, epoch):
        return False
    if cache is not None:
        cache.contexts[key] = identity
        cache.pending_contexts.discard(key)
    return True


def observe_applications(
    config: Settings, fields: TerminalFields, state: CollectorState
) -> None:
    if not config.event_observers:
        return
    with application_cache(config) as cache:
        active_key = json.dumps([fields.tmux_socket, fields.client_tty])
        previous = cache.active_panes.get(active_key)
        force = previous != fields.pane_id
        accepted = True
        for command in config.event_observers:
            try:
                output = subprocess.run(
                    command,
                    input=fields.model_dump_json(),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    check=True,
                    timeout=2,
                ).stdout
                if not output.strip():
                    continue
                payload = ApplicationInput.model_validate_json(output)
                if payload.title is None:
                    accepted = False
                    continue
                epoch = time.time()
                event = ApplicationActivity(
                    **(fields.model_dump() | {"cwd": payload.cwd or fields.cwd}),
                    at=timestamp(epoch),
                    collector_run_id=state.run_id,
                    app_name=payload.app,
                    app_session_id=payload.session_id,
                    event_name=payload.event,
                    app_title=payload.title,
                )
                if not append_application(config, event, state, epoch, cache, force):
                    accepted = False
            except (OSError, ValueError, subprocess.SubprocessError):
                accepted = False
        if accepted:
            cache.active_panes[active_key] = fields.pane_id


def record_application(config: Settings, args: argparse.Namespace) -> None:
    epoch = time.time()
    state = recording_state(config)
    if state is None:
        return
    payload = ApplicationInput.model_validate_json(sys.stdin.read())
    socket = os.environ.get("TMUX", "").rsplit(",", 2)[0]
    pane = os.environ.get("TMUX_PANE", "")
    if payload.title is None:
        if args.on_change and args.force:
            key = json.dumps([payload.app, payload.event, socket, pane or payload.cwd])
            with application_cache(config) as cache:
                cache.pending_contexts.add(key)
        return
    event = ApplicationActivity(
        at=timestamp(epoch),
        collector_run_id=state.run_id,
        app_name=payload.app,
        app_session_id=payload.session_id,
        event_name=payload.event,
        app_title=payload.title,
        cwd=payload.cwd,
        tmux_socket=socket,
        pane_id=pane,
        client_tty="",
        session_id="",
        window_id="",
        command="",
    )
    active_clients: list[str] = []
    if config.integrations.tmux.enable and socket and pane and not args.no_pane_query:
        try:
            output = tmux_output(
                config,
                socket,
                "display-message",
                "-p",
                "-t",
                pane,
                "#{session_id}\t#{window_id}\t#{session_name}\t"
                "#{pane_current_command}\t#{pane_current_path}\t"
                "#{pane_title}",
            ).removesuffix("\n")
            session, window, name, command, cwd, title = output.split("\t", 5)
            event.session_id = session
            event.window_id = window
            event.session_name = name
            event.command = command
            event.pane_title = title
            if not event.cwd:
                event.cwd = cwd
            if args.on_change:
                clients = tmux_output(
                    config, socket, "list-clients", "-F", "#{client_tty}\t#{pane_id}"
                )
                for line in clients.splitlines():
                    tty, active_pane = line.split("\t")
                    if active_pane == pane:
                        active_clients.append(json.dumps([socket, tty]))
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    if args.on_change:
        with application_cache(config) as cache:
            force = args.force or any(
                cache.active_panes.get(key) != pane for key in active_clients
            )
            if append_application(config, event, state, epoch, cache, force):
                for key in active_clients:
                    cache.active_panes[key] = pane
    else:
        append_application(config, event, state, epoch)


def record_tmux_lifecycle(config: Settings, args: argparse.Namespace) -> None:
    if not config.integrations.tmux.enable or not args.socket:
        return
    received_state = recording_state(config)
    if received_state is None or args.at < received_state.accept_since:
        return
    cache_path = config.state_directory / "tmux-clients.json"
    with cache_path.open("a+", encoding="utf-8") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        try:
            cache = TmuxClientCache.model_validate_json(stream.read() or "{}")
        except ValidationError:
            cache = TmuxClientCache()
        state = recording_state(config)
        if (
            state is None
            or state.run_id != received_state.run_id
            or state.accept_since != received_state.accept_since
            or args.at < state.accept_since
        ):
            return
        key = json.dumps([args.socket, args.client])
        previous = cache.clients.get(key)
        if previous is not None and (
            previous.server_pid != args.server_pid
            or previous.server_started_at != args.server_started_at
            or previous.run_id != state.run_id
            or previous.accept_since != state.accept_since
        ):
            previous = None
        event_name = args.reason
        session_id, session_name = args.session, args.session_name
        if args.reason == "client-detached":
            session_id, session_name = "", ""
            if previous is not None:
                session_id, session_name = previous.session_id, previous.session_name
        elif args.reason in {"client-attached", "client-session-changed"}:
            event_name = "client-attached" if previous is None else None
            if args.client:
                cache.clients[key] = TmuxClientSession(
                    server_pid=args.server_pid,
                    server_started_at=args.server_started_at,
                    run_id=state.run_id,
                    accept_since=state.accept_since,
                    session_id=session_id,
                    session_name=session_name,
                )
            else:
                event_name = None
        if event_name is not None:
            event = TmuxLifecycle(
                at=timestamp(args.at),
                collector_run_id=state.run_id,
                event_name=event_name,
                tmux_socket=args.socket,
                server_pid=args.server_pid,
                server_started_at=args.server_started_at,
                client_tty=args.client,
                session_id=session_id,
                session_name=session_name,
                trigger=args.reason,
            )
            if not append_event(config, "terminal.jsonl", event, args.at):
                return
        if args.reason == "client-detached":
            cache.clients.pop(key, None)
        stream.seek(0)
        stream.truncate()
        stream.write(cache.model_dump_json())


def record_tmux(config: Settings, args: argparse.Namespace) -> None:
    if not config.integrations.tmux.enable:
        return
    config.state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    cache_path = config.state_directory / "tmux.json"
    with cache_path.open("a+", encoding="utf-8") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        try:
            cache = TmuxCache.model_validate_json(stream.read() or "{}")
        except ValidationError:
            cache = TmuxCache()
        state = recording_state(config)
        if args.action == "_tmux-event":
            if not args.socket:
                return
            cache.servers.setdefault(args.socket, {})
            sockets = [args.socket]
            if args.reason in {"client-attached", "client-detached"} and args.client:
                cache.servers[args.socket].pop(args.client, None)
                with application_cache(config) as applications:
                    applications.active_panes.pop(
                        json.dumps([args.socket, args.client]), None
                    )
            if args.reason in {"client-detached", "session-closed"}:
                sockets = []
        else:
            sockets = list(cache.servers)
        for socket in sockets:
            if state is None or (
                args.action == "_tmux-poll" and not state.terminal_front
            ):
                break
            try:
                clients = tmux_output(
                    config,
                    socket,
                    "list-clients",
                    "-F",
                    "#{client_tty}\t#{session_id}\t#{window_id}\t#{pane_id}",
                )
                for line in clients.splitlines():
                    tty, session, window, pane = line.split("\t")
                    if args.action == "_tmux-event" and any(
                        (
                            args.client and args.client != tty,
                            args.session and args.session != session,
                            args.window and args.window != window,
                            args.pane and args.pane != pane,
                        )
                    ):
                        continue
                    if not pane:
                        continue
                    command, cwd, pane_title = (
                        tmux_output(
                            config,
                            socket,
                            "display-message",
                            "-p",
                            "-t",
                            pane,
                            "#{pane_current_command}\t#{pane_current_path}\t#{pane_title}",
                        )
                        .removesuffix("\n")
                        .split("\t", 2)
                    )
                    session_name = tmux_output(
                        config,
                        socket,
                        "display-message",
                        "-p",
                        "-t",
                        session,
                        "#{session_name}",
                    ).removesuffix("\n")
                    fields = TerminalFields(
                        tmux_socket=socket,
                        client_tty=tty,
                        session_id=session,
                        window_id=window,
                        pane_id=pane,
                        command=command,
                        cwd=cwd,
                        session_name=session_name,
                        pane_title=pane_title,
                    )
                    if args.action == "_tmux-event":
                        observe_applications(config, fields, state)
                    epoch = time.time()
                    identity = TmuxIdentity(
                        context=fields,
                        run_id=state.run_id,
                        accept_since=state.accept_since,
                        day=datetime.fromtimestamp(epoch).date(),
                    )
                    if cache.servers[socket].get(tty) == identity:
                        continue
                    event = TerminalContext(
                        **fields.model_dump(),
                        collector_run_id=state.run_id,
                        at=timestamp(epoch),
                        reason=getattr(args, "reason", "periodic"),
                    )
                    if append_event(config, "terminal.jsonl", event, epoch):
                        cache.servers[socket][tty] = identity
            except (subprocess.SubprocessError, OSError):
                continue
        stream.seek(0)
        stream.truncate()
        stream.write(cache.model_dump_json())


def visible(value: str) -> str:
    return "".join(
        char if char.isprintable() else f"\\u{ord(char):04x}" for char in value
    )


def load_events(config: Settings, day: date) -> list[Event]:
    directory = config.data_directory / day.isoformat()
    events: list[Event] = []
    if directory.is_dir():
        with day_lock(directory, shared=True):
            paths = {path.name: path for path in directory.glob("*.jsonl")}
            paths.update((path.stem, path) for path in directory.glob("*.jsonl.gz"))
            for name in sorted(paths):
                path = paths[name]
                reader = (
                    gzip.open(path, "rt", encoding="utf-8")
                    if path.suffix == ".gz"
                    else path.open(encoding="utf-8")
                )
                with reader:
                    for number, line in enumerate(reader, 1):
                        try:
                            events.append(EVENTS.validate_json(line))
                        except ValidationError:
                            print(
                                f"Skipping invalid record: {path}:{number}",
                                file=sys.stderr,
                            )
    return sorted(
        events,
        key=lambda event: (datetime.fromisoformat(event.at), event.event_id),
    )


def query(config: Settings, args: argparse.Namespace) -> None:
    day = args.date
    start = datetime.combine(day, args.from_time).astimezone()
    end = datetime.combine(
        day if args.to_time is not None else day + timedelta(days=1),
        args.to_time or wall_time.min,
    ).astimezone()
    if end <= start:
        raise ValueError("--to must be later than --from within the selected day")
    if args.limit < 1 or args.offset < 0:
        raise ValueError("--limit must be positive and --offset non-negative")
    events = load_events(config, day)
    contexts: dict[str, dict[str, Any]] = {}
    starts = {
        event.command_id: event.model_dump(mode="json")
        for event in events
        if isinstance(event, CommandStart)
    }
    matches: list[dict[str, Any]] = []
    for event in events:
        if isinstance(event, ContextChange):
            contexts[event.context_id] = event.model_dump(mode="json")
        elif isinstance(event, ContextUpdate) and event.context_id in contexts:
            contexts[event.context_id] = {
                **contexts[event.context_id],
                "window_title": event.window_title,
            }
        at = datetime.fromisoformat(event.at)
        if not start <= at < end:
            continue
        context = contexts.get(getattr(event, "context_id", ""))
        app = getattr(event, "app_name", "") or (
            context["app_name"] if context else event.source
        )
        app_id = getattr(event, "app_id", "") or (context["app_id"] if context else "")
        if args.app and args.app not in (app, app_id):
            continue
        if args.type and args.type != event.type:
            continue
        item = event.model_dump(mode="json")
        item.update(app=app, local_at=at.astimezone().isoformat())
        if context:
            item["context"] = context
        if isinstance(event, CommandEnd):
            item["command_start"] = starts.get(event.command_id)
        if (
            args.text
            and args.text.casefold()
            not in json.dumps(item, ensure_ascii=False).casefold()
        ):
            continue
        matches.append(item)
    page = matches[args.offset : args.offset + args.limit]
    next_offset = args.offset + len(page)
    print(
        json.dumps(
            {
                "date": day.isoformat(),
                "timezone": {"source": "system-local", "name": start.tzname()},
                "from": start.isoformat(),
                "to": end.isoformat(),
                "total": len(matches),
                "events": page,
                "next_offset": next_offset if next_offset < len(matches) else None,
            },
            ensure_ascii=False,
        )
    )


def local_time(value: str) -> wall_time:
    result = wall_time.fromisoformat(value)
    if result.tzinfo is not None:
        raise ValueError("Use a local time without a UTC offset")
    return result


def show(config: Settings, args: argparse.Namespace) -> None:
    events = load_events(config, date.fromisoformat(args.date))
    contexts = {
        event.context_id: event for event in events if isinstance(event, ContextChange)
    }
    starts = {event.command_id for event in events if isinstance(event, CommandStart)}
    ends = {event.command_id for event in events if isinstance(event, CommandEnd)}
    for event in events:
        context = contexts.get(getattr(event, "context_id", ""))
        app = getattr(event, "app_name", "") or (
            context.app_name if context else event.source
        )
        app_id = getattr(event, "app_id", "") or (context.app_id if context else "")
        if args.app and args.app not in (app, app_id):
            continue
        if args.details:
            print(event.model_dump_json(indent=2, exclude_unset=True))
            continue
        match event:
            case ContextChange() | ContextUpdate():
                detail = event.window_title
            case AppLifecycle():
                detail = f"{event.app_id} · pid {event.pid}"
            case WindowLifecycle():
                detail = f"{event.window_title} · window {event.window_id}"
            case IdleState():
                detail = f"{event.state} · no input for {event.idle_seconds:.0f}s"
            case TextSnapshot():
                detail = f"{event.result} · {len(event.text.encode())} bytes"
            case LocationSnapshot():
                detail = event.summary
                if event.result != "found":
                    detail += f" [{event.result}]"
                if event.partial:
                    detail += " [partial]"
                if event.missing_fields:
                    detail += f" [missing: {', '.join(event.missing_fields)}]"
            case TerminalContext():
                detail = " · ".join(
                    value
                    for value in (
                        event.session_name,
                        event.cwd,
                        event.pane_id,
                        event.command,
                        event.pane_title,
                    )
                    if value
                )
            case TmuxLifecycle():
                detail = " · ".join(
                    value
                    for value in (
                        event.event_name,
                        event.session_name,
                        event.session_id,
                        event.client_tty,
                        event.tmux_socket,
                    )
                    if value
                )
                if event.trigger == "client-session-changed":
                    detail += " [first observed]"
            case ShellSession():
                detail = " · ".join(
                    value
                    for value in (
                        event.shell_session_id,
                        event.tty,
                        event.cwd,
                        event.pane_id,
                    )
                    if value
                )
                if event.exit_code is not None:
                    detail += f" · exit {event.exit_code}"
            case ApplicationActivity():
                detail = " · ".join(
                    value
                    for value in (
                        event.event_name,
                        event.app_title,
                        event.cwd,
                        event.session_name,
                        event.pane_id,
                        event.command,
                    )
                    if value
                )
            case CommandStart():
                detail = event.command[:120]
                if event.command_id not in ends:
                    detail += " [completion not present in this day]"
            case CommandEnd():
                detail = f"exit {event.exit_code} · {event.duration_seconds:.3f}s"
                if event.command_id not in starts:
                    detail += " [start not present in this day]"
            case RecordingState():
                detail = event.reason
        print(visible(f"{event.at}  {app or event.source}  {event.type}  {detail}"))


def control(action: Literal["start", "pause"]) -> None:
    command = (
        'local recorder = assert(package.loaded["activity-history"], '
        '"Activity history is not loaded; reload Hammerspoon"); '
        f'print(hs.json.encode(recorder.control("{action}")))'
    )
    result = subprocess.run(
        [
            "/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs",
            "-t",
            "5",
            "-c",
            command,
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    state = CollectorState.model_validate_json(result.stdout)
    print(state.model_dump_json(indent=2, exclude_none=True))


def run() -> None:
    os.umask(0o077)
    parser = argparse.ArgumentParser(
        prog="activity-history", description="Local application and terminal history"
    )
    parser.add_argument("--config", required=True, type=Path)
    commands = parser.add_subparsers(
        dest="action",
        required=True,
        metavar="{status,start,pause,today,show,query,record}",
    )
    commands.add_parser("status")
    commands.add_parser("start")
    commands.add_parser("pause")
    commands.add_parser("_init")
    command = commands.add_parser("_archive")
    command.add_argument("--before", type=date.fromisoformat, required=True)
    commands.add_parser("_tmux-poll")
    command = commands.add_parser(
        "record", help="Record an application event from stdin JSON"
    )
    command.add_argument("--no-pane-query", action="store_true")
    command.add_argument("--on-change", action="store_true")
    command.add_argument("--force", action="store_true")
    for name in ("today", "show"):
        command = commands.add_parser(name)
        command.add_argument("--date", default=date.today().isoformat())
        command.add_argument("--app")
        command.add_argument("--details", action="store_true")
    command = commands.add_parser(
        "query", help="Query one local day as JSON without a pager"
    )
    command.add_argument("--date", type=date.fromisoformat, default=date.today())
    command.add_argument(
        "--from",
        dest="from_time",
        type=local_time,
        default=wall_time.min,
        help="Inclusive OS-local time (HH:MM[:SS]); default: midnight",
    )
    command.add_argument(
        "--to",
        dest="to_time",
        type=local_time,
        help="Exclusive OS-local time (HH:MM[:SS]); default: next midnight",
    )
    command.add_argument("--app", help="Exact app name, bundle ID, or source")
    command.add_argument("--type", help="Exact event type, e.g. command_end")
    command.add_argument("--text", help="Case-insensitive search including context")
    command.add_argument("--limit", type=int, default=100)
    command.add_argument("--offset", type=int, default=0)
    for name in ("_shell-start", "_shell-end"):
        command = commands.add_parser(name)
        for field in ("session", "command-id", "cwd"):
            command.add_argument(f"--{field}", required=True)
        command.add_argument("--started", type=float, required=True)
        if name == "_shell-start":
            for field in ("tty", "socket", "pane"):
                command.add_argument(f"--{field}", default="")
        else:
            command.add_argument("--ended", type=float, required=True)
            command.add_argument("--exit-code", type=int, required=True)
    for name in ("_shell-session-start", "_shell-session-end"):
        command = commands.add_parser(name)
        for field in ("session", "cwd"):
            command.add_argument(f"--{field}", required=True)
        for field in ("tty", "socket", "pane"):
            command.add_argument(f"--{field}", default="")
        command.add_argument("--pid", type=int, required=True)
        command.add_argument("--at", type=float, required=True)
        command.set_defaults(exit_code=None)
        if name == "_shell-session-end":
            command.add_argument("--exit-code", type=int, required=True)
            command.add_argument("--command-id", default="")
            command.add_argument("--started", type=float, default=0)
    for name in ("_tmux-event", "_tmux-lifecycle"):
        command = commands.add_parser(name)
        for field in (
            "socket",
            "session",
            "session-name",
            "window",
            "pane",
            "client",
            "reason",
        ):
            command.add_argument(f"--{field}", default="")
        command.add_argument("--server-pid", type=int, required=True)
        command.add_argument("--server-started-at", type=int, required=True)
        if name == "_tmux-lifecycle":
            command.add_argument("--at", type=float, required=True)
    args = parser.parse_args()
    config = Settings.from_file(args.config)
    if args.action == "_init":
        prepare(config)
    elif args.action == "_archive":
        archive(config, args.before)
    elif args.action in ("start", "pause"):
        control(args.action)
    elif args.action == "status":
        state = load_state(config)
        print(
            json.dumps(
                {
                    "dataDirectory": str(config.data_directory),
                    "stateDirectory": str(config.state_directory),
                    "acceptingRecords": recording_state(config) is not None,
                    "collector": state.model_dump(exclude_unset=True) if state else {},
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    elif args.action == "record":
        record_application(config, args)
    elif args.action in ("_shell-session-start", "_shell-session-end"):
        record_shell_session(config, args)
    elif args.action.startswith("_shell-"):
        record_shell(config, args)
    elif args.action == "_tmux-lifecycle":
        record_tmux_lifecycle(config, args)
    elif args.action.startswith("_tmux-"):
        record_tmux(config, args)
    elif args.action == "query":
        query(config, args)
    else:
        show(config, args)


def main() -> int:
    try:
        run()
    except (OSError, EOFError, ValueError, subprocess.SubprocessError) as error:
        print(f"activity-history: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
