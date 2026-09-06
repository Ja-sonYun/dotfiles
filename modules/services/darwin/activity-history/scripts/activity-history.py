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
from datetime import date, datetime, timezone
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


class TerminalContext(EventBase, TerminalFields):
    type: Literal["terminal_context"] = "terminal_context"
    source: Literal["tmux"] = "tmux"
    reason: str


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


Event = Annotated[
    ContextChange
    | ContextUpdate
    | TextSnapshot
    | LocationSnapshot
    | RecordingState
    | TerminalContext
    | CommandStart
    | CommandEnd,
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
    with (directory / ".history.lock").open("a") as lock:
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


def record_tmux(config: Settings, args: argparse.Namespace) -> None:
    if not config.integrations.tmux.enable:
        return
    state = recording_state(config)
    if state is None or (args.action == "_tmux-poll" and not state.terminal_front):
        return
    cache_path = config.state_directory / "tmux.json"
    with cache_path.open("a+", encoding="utf-8") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.seek(0)
        try:
            cache = TmuxCache.model_validate_json(stream.read() or "{}")
        except ValidationError:
            cache = TmuxCache()
        if args.action == "_tmux-event":
            if not args.socket:
                return
            cache.servers.setdefault(args.socket, {})
            sockets = [args.socket]
        else:
            sockets = list(cache.servers)
        for socket in sockets:
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
                    command, cwd = (
                        tmux_output(
                            config,
                            socket,
                            "display-message",
                            "-p",
                            "-t",
                            pane,
                            "#{pane_current_command}\t#{pane_current_path}",
                        )
                        .removesuffix("\n")
                        .split("\t", 1)
                    )
                    fields = TerminalFields(
                        tmux_socket=socket,
                        client_tty=tty,
                        session_id=session,
                        window_id=window,
                        pane_id=pane,
                        command=command,
                        cwd=cwd,
                    )
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


def show(config: Settings, args: argparse.Namespace) -> None:
    directory = config.data_directory / date.fromisoformat(args.date).isoformat()
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
    contexts = {
        event.context_id: event for event in events if isinstance(event, ContextChange)
    }
    starts = {event.command_id for event in events if isinstance(event, CommandStart)}
    ends = {event.command_id for event in events if isinstance(event, CommandEnd)}
    for event in sorted(events, key=lambda item: (item.at, item.event_id)):
        context = contexts.get(getattr(event, "context_id", ""))
        app = context.app_name if context else ""
        if args.app and (context is None or args.app not in (app, context.app_id)):
            continue
        if args.details:
            print(event.model_dump_json(indent=2, exclude_unset=True))
            continue
        match event:
            case ContextChange() | ContextUpdate():
                detail = event.window_title
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
                detail = f"{event.cwd} · {event.pane_id} · {event.command}"
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
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("status")
    commands.add_parser("start")
    commands.add_parser("pause")
    commands.add_parser("_init")
    command = commands.add_parser("_archive")
    command.add_argument("--before", type=date.fromisoformat, required=True)
    commands.add_parser("_tmux-poll")
    for name in ("today", "show"):
        command = commands.add_parser(name)
        command.add_argument("--date", default=date.today().isoformat())
        command.add_argument("--app")
        command.add_argument("--details", action="store_true")
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
    command = commands.add_parser("_tmux-event")
    for field in ("socket", "session", "window", "pane", "client", "reason"):
        command.add_argument(f"--{field}", default="")
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
    elif args.action.startswith("_shell-"):
        record_shell(config, args)
    elif args.action.startswith("_tmux-"):
        record_tmux(config, args)
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
