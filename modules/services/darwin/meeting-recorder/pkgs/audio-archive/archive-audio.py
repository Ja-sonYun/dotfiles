#!@PYTHON@
from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path
from types import FrameType
from typing import Any

FFMPEG = "@FFMPEG@"
FFPROBE = "@FFPROBE@"
ARCHIVE_TAG = "aac-mono-32k-v1"

_active_process: subprocess.Popen[str] | None = None
_process_starting = False
_pending_termination_signal: int | None = None
_diagnostics_enabled = False
_diagnostic_stage = "archiving"


class ArchiveError(RuntimeError):
    pass


def handle_termination(signal_number: int, _frame: FrameType | None) -> None:
    global _pending_termination_signal

    if _process_starting:
        _pending_termination_signal = signal_number
        return
    if _active_process is not None and _active_process.poll() is None:
        try:
            _active_process.terminate()
        except ProcessLookupError:
            pass
    raise ArchiveError(f"Interrupted by signal {signal_number}")


def install_signal_handlers() -> None:
    signal.signal(signal.SIGINT, handle_termination)
    signal.signal(signal.SIGTERM, handle_termination)


def stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def emit_event(enabled: bool, status: str, **values: object) -> None:
    if not enabled:
        return
    print(
        json.dumps(
            {"status": status, **values},
            ensure_ascii=False,
            separators=(",", ":"),
        ),
        flush=True,
    )


def diagnostic(event: str, level: str = "info", **values: object) -> None:
    emit_event(
        _diagnostics_enabled,
        "diagnostic",
        event=event,
        level=level,
        stage=_diagnostic_stage,
        pid=os.getpid(),
        **values,
    )


def run_archive_command(command: list[str]) -> str:
    global _active_process, _pending_termination_signal, _process_starting

    process: subprocess.Popen[str] | None = None
    started = time.monotonic()
    diagnostic("archive_command_starting", executable=command[0])
    try:
        _process_starting = True
        try:
            process = subprocess.Popen(
                command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
            )
            _active_process = process
            diagnostic("archive_command_started", child_pid=process.pid)
        finally:
            _process_starting = False
        pending_signal = _pending_termination_signal
        _pending_termination_signal = None
        if pending_signal is not None:
            handle_termination(pending_signal, None)
        stdout, stderr = process.communicate()
        diagnostic(
            "archive_command_exited",
            "error" if process.returncode else "info",
            child_pid=process.pid,
            exit_code=process.returncode,
            elapsed_seconds=time.monotonic() - started,
            stderr=stderr[-8192:],
        )
        if process.returncode != 0:
            raise ArchiveError(stderr.strip() or "Audio archive command failed")
        return stdout
    finally:
        _process_starting = False
        _pending_termination_signal = None
        if process is not None:
            stop_process(process)
            if _active_process is process:
                _active_process = None


def inspect_archive_audio(source: Path) -> tuple[list[dict[str, Any]], bool]:
    if source.suffix.lower() != ".mov":
        raise ArchiveError("Audio archive requires a MOV recording")
    payload = json.loads(
        run_archive_command(
            [
                FFPROBE,
                "-v",
                "error",
                "-show_entries",
                (
                    "stream=index,codec_type,codec_name,channels,sample_rate,start_time,duration:"
                    "format=format_name:format_tags=major_brand,meeting_recorder_archive"
                ),
                "-of",
                "json",
                str(source),
            ]
        )
    )
    container = payload.get("format", {})
    if (
        "mov" not in container.get("format_name", "").split(",")
        or container.get("tags", {}).get("major_brand", "").strip() != "qt"
    ):
        raise ArchiveError("Audio archive requires a QuickTime MOV container")
    streams = payload.get("streams", [])
    if len(streams) != 2 or any(
        stream.get("codec_type") != "audio" for stream in streams
    ):
        raise ArchiveError("Audio archive requires exactly two audio tracks")
    for stream in streams:
        for field in ("start_time", "duration"):
            try:
                value = float(stream[field])
            except (KeyError, TypeError, ValueError) as error:
                raise ArchiveError(f"Missing audio {field}") from error
            if not math.isfinite(value) or (field == "duration" and value <= 0):
                raise ArchiveError(f"Invalid audio {field}")
            stream[field] = value
    archived = (
        payload.get("format", {}).get("tags", {}).get("meeting_recorder_archive")
        == ARCHIVE_TAG
    )
    return streams, archived


def require_archive_format(streams: list[dict[str, Any]]) -> None:
    if any(
        stream.get("codec_name") != "aac"
        or stream.get("channels") != 1
        or stream.get("sample_rate") != "48000"
        for stream in streams
    ):
        raise ArchiveError("Archive must contain two mono 48 kHz AAC tracks")


def archive_identity(source: Path) -> dict[str, str | int]:
    status = source.stat()
    return {
        "source": str(source.resolve()),
        "device": status.st_dev,
        "inode": status.st_ino,
        "size": status.st_size,
        "mtime_ns": status.st_mtime_ns,
        "ctime_ns": status.st_ctime_ns,
        "archive_tag": ARCHIVE_TAG,
    }


def find_ready_archive(
    work_root: Path, identity: dict[str, str | int]
) -> tuple[Path, int] | None:
    for directory in sorted(work_root.glob("archive-audio-*")):
        if directory.is_symlink() or not (directory / "ready.json").is_file():
            continue
        try:
            descriptor = os.open(directory / "lock", os.O_CREAT | os.O_RDWR, 0o600)
        except FileNotFoundError:
            continue
        selected = False
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            try:
                manifest = json.loads((directory / "ready.json").read_text())
            except (OSError, ValueError):
                continue
            if manifest != identity or not (directory / "archive.mov").is_file():
                continue
            selected = True
            return directory, descriptor
        finally:
            if not selected:
                os.close(descriptor)
    return None


def install_archive(source: Path, work_directory: Path) -> None:
    manifest = json.loads((work_directory / "ready.json").read_text())
    if manifest != archive_identity(source):
        raise ArchiveError("Recording changed after archive preparation")
    temporary = work_directory / "archive.mov"
    temporary.chmod(source.stat().st_mode & 0o777)
    os.replace(temporary, source)
    diagnostic("archive_installed")


def prepare_archive(source: Path, work_directory: Path) -> bool:
    original, archived = inspect_archive_audio(source)
    if archived:
        require_archive_format(original)
        diagnostic("archive_skipped", reason="already_archived")
        return False
    temporary = work_directory / "archive.mov"
    run_archive_command(
        [
            FFMPEG,
            "-nostdin",
            "-v",
            "error",
            "-n",
            "-copyts",
            "-start_at_zero",
            "-i",
            str(source),
            "-map",
            "0:a:0",
            "-map",
            "0:a:1",
            "-c:a",
            "aac",
            "-b:a",
            "32k",
            "-ac:a",
            "1",
            "-ar:a",
            "48000",
            "-avoid_negative_ts",
            "disabled",
            "-use_editlist",
            "1",
            "-movflags",
            "+use_metadata_tags",
            # Avoid appending copied metadata to the container's ftyp brand.
            "-metadata",
            "major_brand=",
            "-metadata",
            f"meeting_recorder_archive={ARCHIVE_TAG}",
            "-f",
            "mov",
            str(temporary),
        ]
    )
    compressed, tagged = inspect_archive_audio(temporary)
    require_archive_format(compressed)
    if not tagged:
        raise ArchiveError("Archive completion tag was not preserved")
    for before, after in zip(original, compressed, strict=True):
        if abs(before["duration"] - after["duration"]) > 0.05:
            raise ArchiveError("Archive changed an audio track duration")
    original_offset = original[1]["start_time"] - original[0]["start_time"]
    compressed_offset = compressed[1]["start_time"] - compressed[0]["start_time"]
    if abs(original_offset - compressed_offset) > 0.05:
        raise ArchiveError("Archive changed the relative audio track timing")
    run_archive_command(
        [
            FFMPEG,
            "-nostdin",
            "-v",
            "error",
            "-xerror",
            "-i",
            str(temporary),
            "-map",
            "0:a:0",
            "-map",
            "0:a:1",
            "-f",
            "null",
            "-",
        ]
    )
    diagnostic(
        "archive_size_compared",
        original_bytes=source.stat().st_size,
        compressed_bytes=temporary.stat().st_size,
    )
    if temporary.stat().st_size < source.stat().st_size:
        return True
    diagnostic("archive_skipped", reason="not_smaller")
    return False


def main() -> int:
    global _diagnostics_enabled

    install_signal_handlers()
    parser = argparse.ArgumentParser(
        description="Compress a meeting recording after its transcripts are saved."
    )
    parser.add_argument("input", type=Path, help="Two-track QuickTime MOV recording")
    parser.add_argument("--progress-json", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    _diagnostics_enabled = arguments.progress_json
    started = time.monotonic()
    diagnostic("job_started")
    work_directory: Path | None = None
    work_lock: int | None = None
    archive_ready = False

    try:
        source = arguments.input.expanduser().resolve()
        if not source.is_file():
            raise ArchiveError(f"Input file not found: {source}")
        base = source.with_suffix("")
        if (
            not Path(f"{base}.transcript.json").is_file()
            or not Path(f"{base}.transcript.md").is_file()
        ):
            raise ArchiveError(
                "Audio archive requires existing JSON and Markdown transcripts"
            )

        work_root = source.parent / ".tmp"
        work_root.mkdir(exist_ok=True)
        emit_event(arguments.progress_json, "progress", phase="archiving", progress=0)
        identity = archive_identity(source)
        recovered = find_ready_archive(work_root, identity)
        if recovered is None:
            work_directory = Path(
                tempfile.mkdtemp(prefix="archive-audio-", dir=work_root)
            )
            work_lock = os.open(work_directory / "lock", os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(work_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            archive_ready = prepare_archive(source, work_directory)
            if archive_ready:
                if identity != archive_identity(source):
                    raise ArchiveError("Recording changed during archive preparation")
                pending = work_directory / "pending.json"
                pending.write_text(json.dumps(identity), encoding="utf-8")
                os.replace(pending, work_directory / "ready.json")
        else:
            work_directory, work_lock = recovered
            archive_ready = True
            diagnostic("archive_recovered", directory=str(work_directory))
        if archive_ready:
            install_archive(source, work_directory)
        diagnostic("job_finished", elapsed_seconds=time.monotonic() - started)
        emit_event(
            arguments.progress_json,
            "finished",
            phase="archiving",
            progress=100,
            source_path=str(source),
        )
        if not arguments.progress_json:
            print(source)
        return 0
    except (OSError, ValueError, ArchiveError) as error:
        diagnostic(
            "job_failed",
            "error",
            elapsed_seconds=time.monotonic() - started,
            traceback=traceback.format_exc(),
        )
        print(f"archive-audio: {error}", file=sys.stderr)
        return 1
    finally:
        try:
            if work_directory is not None:
                if archive_ready and (work_directory / "archive.mov").is_file():
                    print(
                        f"archive-audio: recovery files preserved in {work_directory}",
                        file=sys.stderr,
                    )
                else:
                    shutil.rmtree(work_directory, ignore_errors=True)
        finally:
            if work_lock is not None:
                os.close(work_lock)


if __name__ == "__main__":
    raise SystemExit(main())
