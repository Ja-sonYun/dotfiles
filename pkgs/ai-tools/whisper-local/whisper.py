#!@PYTHON@
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from types import FrameType
from typing import Any


FFMPEG = "@FFMPEG@"
FFPROBE = "@FFPROBE@"
WHISPER_CLI = "@WHISPER_CLI@"
WHISPER_MODEL = "@WHISPER_MODEL@"
VAD_MODEL = "@VAD_MODEL@"
STALE_WORK_DIRECTORY_SECONDS = 24 * 60 * 60
WORK_DIRECTORY_PATTERN = re.compile(r"^whisper-(\d+)-\d+$")
TERMINATION_SIGNALS = {signal.SIGINT, signal.SIGTERM}
ARCHIVE_TAG = "aac-mono-32k-v1"

_active_process: subprocess.Popen[str] | None = None
_process_starting = False
_pending_termination_signal: int | None = None
_diagnostics_enabled = False
_diagnostic_stage = "initializing"


class TranscriptionError(RuntimeError):
    pass


@dataclass(frozen=True)
class AudioStream:
    index: int
    start_ms: int


@dataclass(frozen=True)
class TrackResult:
    channel: str
    speaker: str
    stream_index: int
    start_offset_ms: int
    language: str | None
    segments: list[dict[str, Any]]


def process_is_running(process_id: int) -> bool:
    try:
        os.kill(process_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def has_output_backups(work_directory: Path) -> bool:
    try:
        return any(
            entry.name.startswith("previous-") for entry in work_directory.iterdir()
        )
    except OSError:
        return True


def cleanup_stale_work_directories(work_root: Path) -> None:
    if not work_root.is_dir():
        return
    try:
        entries = list(work_root.iterdir())
    except OSError:
        return

    cutoff = time.time() - STALE_WORK_DIRECTORY_SECONDS
    for entry in entries:
        match = WORK_DIRECTORY_PATTERN.fullmatch(entry.name)
        if not match or entry.is_symlink() or not entry.is_dir():
            continue
        try:
            is_stale = entry.stat().st_mtime < cutoff
        except OSError:
            continue
        if (
            is_stale
            and not process_is_running(int(match.group(1)))
            and not has_output_backups(entry)
        ):
            shutil.rmtree(entry, ignore_errors=True)


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
    raise TranscriptionError(f"Interrupted by signal {signal_number}")


def install_signal_handlers() -> None:
    signal.signal(signal.SIGINT, handle_termination)
    signal.signal(signal.SIGTERM, handle_termination)


@contextmanager
def blocked_termination_signals() -> Iterator[None]:
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, TERMINATION_SIGNALS)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


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


def parse_track(value: str) -> tuple[int, str]:
    index, separator, label = value.partition(":")
    if (
        not separator
        or not index.isdecimal()
        or not label.strip()
        or any(character in label for character in "\r\n")
    ):
        raise argparse.ArgumentTypeError(
            "Expected a nonnegative audio index and label: INDEX:LABEL"
        )
    return int(index), label.strip()


def parse_echo(value: str) -> tuple[int, int]:
    target, separator, reference = value.partition(":")
    if not separator or not target.isdecimal() or not reference.isdecimal():
        raise argparse.ArgumentTypeError("Expected audio indices: TARGET:REFERENCE")
    return int(target), int(reference)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Transcribe audio and video locally with whisper.cpp."
    )
    parser.add_argument("input", type=Path, help="Audio or video file to transcribe")
    parser.add_argument(
        "--track",
        action="append",
        type=parse_track,
        metavar="INDEX:LABEL",
        help="Select a zero-based audio track and speaker label; repeat for multiple tracks",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output base path without .json or .md",
    )
    parser.add_argument("--language", default="auto", help="Whisper language code")
    parser.add_argument(
        "--model",
        type=Path,
        default=Path(WHISPER_MODEL),
        help="Whisper model file (default: bundled large-v3)",
    )
    parser.add_argument(
        "--format",
        choices=("md", "json", "both"),
        default="both",
        help="Output format (default: both)",
    )
    parser.add_argument(
        "--suppress-echo",
        type=parse_echo,
        metavar="TARGET:REFERENCE",
        help="Remove overlapping duplicate speech from the target audio track",
    )
    parser.add_argument(
        "--archive-audio",
        action="store_true",
        help="After transcription, replace a two-track QuickTime MOV with mono 32 kbps AAC tracks",
    )
    parser.add_argument("--progress-json", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.track is None:
        arguments.track = [(0, "Audio")]
    indices = [index for index, _ in arguments.track]
    if len(set(indices)) != len(indices):
        parser.error("Each audio track may only be selected once")
    if arguments.suppress_echo is not None:
        target, reference = arguments.suppress_echo
        if target == reference or target not in indices or reference not in indices:
            parser.error("--suppress-echo requires two distinct selected audio tracks")
    if arguments.archive_audio and arguments.output is not None:
        parser.error("--archive-audio requires the default output location")
    return arguments


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


@contextmanager
def log_stage(name: str, **values: object) -> Iterator[None]:
    global _diagnostic_stage

    previous = _diagnostic_stage
    _diagnostic_stage = name
    started = time.monotonic()
    diagnostic("stage_started", **values)
    try:
        yield
    except (OSError, ValueError, TranscriptionError):
        diagnostic("stage_failed", "error", elapsed_seconds=time.monotonic() - started)
        raise
    else:
        diagnostic("stage_finished", elapsed_seconds=time.monotonic() - started)
    finally:
        _diagnostic_stage = previous


def parse_start_ms(value: object) -> int:
    if not isinstance(value, (int, float, str)) or isinstance(value, bool):
        return 0
    try:
        return round(float(value) * 1000)
    except ValueError:
        return 0


def probe_audio_streams(source: Path) -> list[AudioStream]:
    started = time.monotonic()
    diagnostic("probe_started", executable=FFPROBE)
    result = subprocess.run(
        [
            FFPROBE,
            "-v",
            "error",
            "-select_streams",
            "a",
            "-show_entries",
            "stream=index,start_time,duration",
            "-of",
            "json",
            str(source),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    diagnostic(
        "probe_exited",
        "error" if result.returncode else "info",
        exit_code=result.returncode,
        elapsed_seconds=time.monotonic() - started,
        stderr=result.stderr[-8192:],
    )
    if result.returncode != 0:
        message = result.stderr.strip().splitlines()
        raise TranscriptionError(
            message[-1] if message else "Could not inspect audio streams"
        )

    payload = json.loads(result.stdout)
    if not isinstance(payload, dict):
        raise TranscriptionError("ffprobe returned invalid JSON")
    raw_streams = payload.get("streams")
    if not isinstance(raw_streams, list):
        raise TranscriptionError("No audio streams found")

    streams: list[AudioStream] = []
    for raw_stream in raw_streams:
        if not isinstance(raw_stream, dict) or not isinstance(
            raw_stream.get("index"), int
        ):
            continue
        streams.append(
            AudioStream(
                index=raw_stream["index"],
                start_ms=parse_start_ms(raw_stream.get("start_time")),
            )
        )
    if not streams:
        raise TranscriptionError("No audio streams found")
    diagnostic(
        "streams_detected",
        count=len(streams),
        streams=[
            {key: stream.get(key) for key in ("index", "start_time", "duration")}
            for stream in raw_streams
            if isinstance(stream, dict)
        ],
    )
    return streams


def extract_audio(source: Path, stream: AudioStream, destination: Path) -> None:
    started = time.monotonic()
    diagnostic("extraction_started", executable=FFMPEG, stream_index=stream.index)
    result = subprocess.run(
        [
            FFMPEG,
            "-v",
            "error",
            "-y",
            "-i",
            str(source),
            "-map",
            f"0:{stream.index}",
            "-vn",
            "-af",
            "aresample=async=1",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(destination),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    diagnostic(
        "extraction_exited",
        "error" if result.returncode else "info",
        exit_code=result.returncode,
        elapsed_seconds=time.monotonic() - started,
        stderr=result.stderr[-8192:],
    )
    if result.returncode != 0:
        message = result.stderr.strip().splitlines()
        raise TranscriptionError(message[-1] if message else "Could not extract audio")


def whisper_error(lines: list[str]) -> str:
    useful = [
        line.strip() for line in lines if line.strip() and "progress =" not in line
    ]
    return useful[-1] if useful else "whisper-cli exited with an error"


def run_whisper(
    audio_path: Path,
    output_base: Path,
    language: str,
    model: Path,
    phase: str,
    progress_start: int,
    progress_end: int,
    progress_json: bool,
) -> dict[str, Any]:
    global _active_process, _pending_termination_signal, _process_starting

    process: subprocess.Popen[str] | None = None
    started = time.monotonic()
    diagnostic(
        "whisper_starting",
        executable=WHISPER_CLI,
        model=str(model),
        vad_model=VAD_MODEL,
        language=language,
        track=phase,
        input_bytes=audio_path.stat().st_size,
    )
    try:
        _process_starting = True
        try:
            process = subprocess.Popen(
                [
                    WHISPER_CLI,
                    "-m",
                    str(model),
                    "-f",
                    str(audio_path),
                    "-l",
                    language,
                    "-oj",
                    "-of",
                    str(output_base),
                    "-pp",
                    "-np",
                    "--vad",
                    "-vm",
                    VAD_MODEL,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            _active_process = process
            diagnostic("whisper_started", child_pid=process.pid)
        finally:
            _process_starting = False

        pending_signal = _pending_termination_signal
        _pending_termination_signal = None
        if pending_signal is not None:
            handle_termination(pending_signal, None)

        if process.stderr is None:
            raise TranscriptionError("Could not read whisper-cli progress")

        stderr_lines: list[str] = []
        last_progress = -1
        for line in process.stderr:
            stderr_lines.append(line)
            if "progress =" not in line:
                diagnostic("whisper_stderr", detail=line.rstrip()[:8192])
            for match in re.finditer(r"progress\s*=\s*(\d+)%", line):
                track_progress = min(100, max(0, int(match.group(1))))
                progress = round(
                    progress_start
                    + (progress_end - progress_start) * track_progress / 100
                )
                if progress != last_progress:
                    emit_event(
                        progress_json,
                        "progress",
                        phase=phase,
                        progress=progress,
                    )
                    last_progress = progress
        return_code = process.wait()
        diagnostic(
            "whisper_exited",
            "error" if return_code else "info",
            child_pid=process.pid,
            exit_code=return_code,
            elapsed_seconds=time.monotonic() - started,
            last_progress=last_progress,
            stderr="".join(stderr_lines[-50:])[-8192:] if return_code else None,
        )
    finally:
        _process_starting = False
        _pending_termination_signal = None
        if process is not None:
            stop_process(process)
            if _active_process is process:
                _active_process = None
    if return_code != 0:
        raise TranscriptionError(whisper_error(stderr_lines))

    emit_event(progress_json, "progress", phase=phase, progress=progress_end)
    json_path = Path(f"{output_base}.json")
    if not json_path.is_file():
        raise TranscriptionError("whisper-cli did not create JSON output")
    payload = json.loads(json_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise TranscriptionError("whisper-cli returned invalid JSON")
    diagnostic("whisper_output_loaded", bytes=json_path.stat().st_size)
    return payload


def timestamp_ms(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    match = re.search(r"(\d+):(\d+):(\d+)[,.](\d+)", value)
    if not match:
        return None
    hours, minutes, seconds, fraction = match.groups()
    milliseconds = int(fraction[:3].ljust(3, "0"))
    return ((int(hours) * 60 + int(minutes)) * 60 + int(seconds)) * 1000 + milliseconds


def segment_time(segment: dict[str, Any], name: str) -> int | None:
    offsets = segment.get("offsets")
    if isinstance(offsets, dict):
        value = offsets.get(name)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return round(value)
    timestamps = segment.get("timestamps")
    if isinstance(timestamps, dict):
        return timestamp_ms(timestamps.get(name))
    return None


def parse_segments(
    payload: dict[str, Any],
    channel: str,
    speaker: str,
    start_offset_ms: int,
) -> list[dict[str, Any]]:
    transcription = payload.get("transcription")
    if not isinstance(transcription, list):
        raise TranscriptionError("whisper-cli JSON has no transcription segments")

    segments: list[dict[str, Any]] = []
    for raw_segment in transcription:
        if not isinstance(raw_segment, dict):
            continue
        text = raw_segment.get("text")
        start_ms = segment_time(raw_segment, "from")
        end_ms = segment_time(raw_segment, "to")
        if not isinstance(text, str) or start_ms is None or end_ms is None:
            continue
        text = text.strip()
        if not text:
            continue
        start_ms += start_offset_ms
        end_ms = max(start_ms, end_ms + start_offset_ms)
        segments.append(
            {
                "start_ms": start_ms,
                "end_ms": end_ms,
                "channel": channel,
                "speaker": speaker,
                "text": text,
            }
        )
    return segments


def detected_language(payload: dict[str, Any]) -> str | None:
    result = payload.get("result")
    if isinstance(result, dict) and isinstance(result.get("language"), str):
        return result["language"]
    return None


def normalized_text(text: str) -> str:
    return re.sub(r"[\W_]+", "", text.casefold(), flags=re.UNICODE)


def is_echo(target: dict[str, Any], reference: dict[str, Any]) -> bool:
    target_text = normalized_text(target["text"])
    reference_text = normalized_text(reference["text"])
    if min(len(target_text), len(reference_text)) < 20:
        return False
    if abs(target["start_ms"] - reference["start_ms"]) > 1500:
        return False

    overlap = min(target["end_ms"], reference["end_ms"]) - max(
        target["start_ms"], reference["start_ms"]
    )
    shortest = min(
        target["end_ms"] - target["start_ms"],
        reference["end_ms"] - reference["start_ms"],
    )
    if shortest <= 0 or overlap / shortest < 0.65:
        return False
    return SequenceMatcher(None, target_text, reference_text).ratio() >= 0.92


def merged_segments(
    results: list[TrackResult], suppress_echo: tuple[int, int] | None
) -> list[dict[str, Any]]:
    segments = sorted(
        (segment for result in results for segment in result.segments),
        key=lambda segment: (
            segment["start_ms"],
            segment["end_ms"],
            segment["channel"],
        ),
    )
    target_channel = f"audio-{suppress_echo[0]}" if suppress_echo else None
    reference_channel = f"audio-{suppress_echo[1]}" if suppress_echo else None
    reference_segments = [
        segment for segment in segments if segment["channel"] == reference_channel
    ]
    merged: list[dict[str, Any]] = []
    reference_start = 0
    for segment in segments:
        if segment["channel"] == target_channel:
            while (
                reference_start < len(reference_segments)
                and reference_segments[reference_start]["end_ms"]
                < segment["start_ms"] - 1500
            ):
                reference_start += 1
            duplicate = False
            for candidate in reference_segments[reference_start:]:
                if candidate["start_ms"] > segment["end_ms"] + 1500:
                    break
                if is_echo(segment, candidate):
                    duplicate = True
                    break
            if duplicate:
                continue
        merged.append(segment)

    return [{"id": index, **segment} for index, segment in enumerate(merged)]


def format_timestamp(milliseconds: int) -> str:
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    seconds, milliseconds = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}.{milliseconds:03d}"


def render_markdown(
    source: Path,
    results: list[TrackResult],
    segments: list[dict[str, Any]],
    model_name: str,
) -> str:
    speakers = ", ".join(f"{result.speaker} = {result.channel}" for result in results)
    lines = [
        "# Transcript",
        "",
        f"- Source: {source.name}",
        f"- Model: Whisper {model_name}",
        f"- Speakers: {speakers}",
        "",
    ]
    if not segments:
        lines.append("_No speech detected._")
    else:
        for segment in segments:
            lines.append(
                f"[{format_timestamp(segment['start_ms'])}] "
                f"**{segment['speaker']}:** {segment['text']}"
            )
    return "\n".join(lines) + "\n"


def output_paths(source: Path, requested_base: Path | None) -> tuple[Path, Path]:
    if requested_base is None:
        base = Path(f"{source.with_suffix('')}.transcript")
    else:
        base = requested_base.expanduser().resolve()
    return Path(f"{base}.json"), Path(f"{base}.md")


def replace_output_pair(
    replacements: list[tuple[Path, Path]],
    work_directory: Path,
) -> None:
    backups: list[tuple[Path, Path]] = []
    installed: list[Path] = []
    with blocked_termination_signals():
        try:
            for _, destination in replacements:
                if destination.exists():
                    backup = work_directory / f"previous-{destination.name}"
                    os.replace(destination, backup)
                    backups.append((backup, destination))
            for temporary, destination in replacements:
                os.replace(temporary, destination)
                installed.append(destination)
        except OSError as write_error:
            rollback_errors: list[OSError] = []
            for destination in installed:
                try:
                    destination.unlink(missing_ok=True)
                except OSError as rollback_error:
                    rollback_errors.append(rollback_error)
            for backup, destination in reversed(backups):
                try:
                    os.replace(backup, destination)
                except OSError as rollback_error:
                    rollback_errors.append(rollback_error)
            if rollback_errors:
                raise TranscriptionError(
                    "Output replacement failed and rollback was incomplete; "
                    f"any remaining backups are in {work_directory}"
                ) from write_error
            raise


def write_outputs(
    source: Path,
    results: list[TrackResult],
    segments: list[dict[str, Any]],
    json_path: Path,
    markdown_path: Path,
    work_directory: Path,
    model_name: str,
    output_format: str,
) -> None:
    payload = {
        "schema_version": 1,
        "source_file": source.name,
        "created_at": datetime.now(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "engine": {
            "name": "whisper.cpp",
            "model": model_name,
            "vad": "silero-v6.2.0",
        },
        "tracks": [
            {
                "channel": result.channel,
                "speaker": result.speaker,
                "stream_index": result.stream_index,
                "start_offset_ms": result.start_offset_ms,
                "language": result.language,
            }
            for result in results
        ],
        "segments": segments,
    }
    temporary_json = work_directory / "transcript.json"
    temporary_markdown = work_directory / "transcript.md"
    replacements: list[tuple[Path, Path]] = []
    if output_format in ("json", "both"):
        temporary_json.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        replacements.append((temporary_json, json_path))
    if output_format in ("md", "both"):
        temporary_markdown.write_text(
            render_markdown(source, results, segments, model_name),
            encoding="utf-8",
        )
        replacements.append((temporary_markdown, markdown_path))
    replace_output_pair(replacements, work_directory)


def transcribe_track(
    source: Path,
    stream: AudioStream,
    common_start_ms: int,
    channel: str,
    speaker: str,
    language: str,
    model: Path,
    phase: str,
    progress_start: int,
    progress_end: int,
    progress_json: bool,
    work_directory: Path,
) -> TrackResult:
    audio_path = work_directory / f"{channel}.wav"
    whisper_output = work_directory / f"{channel}-whisper"
    with log_stage("extracting", track=channel, stream_index=stream.index):
        extract_audio(source, stream, audio_path)
    with log_stage("whisper", track=channel):
        payload = run_whisper(
            audio_path,
            whisper_output,
            language,
            model,
            phase,
            progress_start,
            progress_end,
            progress_json,
        )
    start_offset_ms = max(0, stream.start_ms - common_start_ms)
    result = TrackResult(
        channel=channel,
        speaker=speaker,
        stream_index=stream.index,
        start_offset_ms=start_offset_ms,
        language=detected_language(payload),
        segments=parse_segments(payload, channel, speaker, start_offset_ms),
    )
    diagnostic(
        "track_finished",
        track=channel,
        segment_count=len(result.segments),
        language=result.language,
        start_offset_ms=start_offset_ms,
    )
    return result


def transcribe(
    source: Path,
    tracks: list[tuple[int, str]],
    language: str,
    model: Path,
    progress_json: bool,
    work_directory: Path,
) -> list[TrackResult]:
    with log_stage("probing"):
        streams = probe_audio_streams(source)
    diagnostic("tracks_selected", indices=[index for index, _ in tracks])
    for index, _ in tracks:
        if index >= len(streams):
            raise TranscriptionError(
                f"Audio track {index} does not exist; input has {len(streams)} audio tracks"
            )
    common_start_ms = min(stream.start_ms for stream in streams)
    return [
        transcribe_track(
            source,
            streams[index],
            common_start_ms,
            f"audio-{index}",
            speaker,
            language,
            model,
            speaker,
            position * 100 // len(tracks),
            (position + 1) * 100 // len(tracks),
            progress_json,
            work_directory,
        )
        for position, (index, speaker) in enumerate(tracks)
    ]


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
            raise TranscriptionError(stderr.strip() or "Audio archive command failed")
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
        raise TranscriptionError("Audio archive requires a MOV recording")
    payload = json.loads(
        run_archive_command(
            [
                FFPROBE,
                "-v",
                "error",
                "-show_entries",
                "stream=index,codec_type,codec_name,channels,sample_rate,start_time,duration:"
                "format=format_name:format_tags=major_brand,meeting_recorder_archive",
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
        raise TranscriptionError("Audio archive requires a QuickTime MOV container")
    streams = payload.get("streams", [])
    if len(streams) != 2 or any(
        stream.get("codec_type") != "audio" for stream in streams
    ):
        raise TranscriptionError("Audio archive requires exactly two audio tracks")
    for stream in streams:
        for field in ("start_time", "duration"):
            try:
                value = float(stream[field])
            except (KeyError, TypeError, ValueError) as error:
                raise TranscriptionError(f"Missing audio {field}") from error
            if not math.isfinite(value) or (field == "duration" and value <= 0):
                raise TranscriptionError(f"Invalid audio {field}")
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
        raise TranscriptionError("Archive must contain two mono 48 kHz AAC tracks")


def archive_audio(source: Path, work_directory: Path) -> None:
    original, archived = inspect_archive_audio(source)
    if archived:
        require_archive_format(original)
        diagnostic("archive_skipped", reason="already_archived")
        return
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
        raise TranscriptionError("Archive completion tag was not preserved")
    for before, after in zip(original, compressed, strict=True):
        if abs(before["duration"] - after["duration"]) > 0.05:
            raise TranscriptionError("Archive changed an audio track duration")
    original_offset = original[1]["start_time"] - original[0]["start_time"]
    compressed_offset = compressed[1]["start_time"] - compressed[0]["start_time"]
    if abs(original_offset - compressed_offset) > 0.05:
        raise TranscriptionError("Archive changed the relative audio track timing")
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
        temporary.chmod(source.stat().st_mode & 0o777)
        os.replace(temporary, source)
        diagnostic("archive_installed")
    else:
        diagnostic("archive_skipped", reason="not_smaller")


def main() -> int:
    global _diagnostics_enabled

    install_signal_handlers()
    arguments = parse_arguments()
    _diagnostics_enabled = arguments.progress_json
    started = time.monotonic()
    diagnostic(
        "job_started", language=arguments.language, archive=arguments.archive_audio
    )
    source = arguments.input.expanduser().resolve()
    if not source.is_file():
        diagnostic("input_missing", "error")
        print(f"whisper: input file not found: {source}", file=sys.stderr)
        return 1
    model = arguments.model.expanduser().absolute()
    if not model.is_file():
        diagnostic("model_missing", "error", model=str(model))
        print(f"whisper: model file not found: {model}", file=sys.stderr)
        return 1

    json_path, markdown_path = output_paths(source, arguments.output)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    work_root = json_path.parent / ".tmp"
    cleanup_stale_work_directories(work_root)
    work_directory = work_root / f"whisper-{os.getpid()}-{time.time_ns()}"
    outputs_written = False
    try:
        diagnostic(
            "input_ready",
            input_bytes=source.stat().st_size,
            model=str(model),
            model_bytes=model.stat().st_size,
            existing_json=json_path.is_file(),
            existing_markdown=markdown_path.is_file(),
        )
        work_directory.mkdir(parents=True)
        emit_event(arguments.progress_json, "progress", phase="preparing", progress=0)
        if arguments.archive_audio:
            with log_stage("archive_inspection"):
                inspect_archive_audio(source)
        with log_stage("transcribing"):
            results = transcribe(
                source,
                arguments.track,
                arguments.language,
                model,
                arguments.progress_json,
                work_directory,
            )
        segments = merged_segments(results, arguments.suppress_echo)
        with log_stage("saving", segment_count=len(segments)):
            write_outputs(
                source,
                results,
                segments,
                json_path,
                markdown_path,
                work_directory,
                model.stem.removeprefix("ggml-"),
                arguments.format,
            )
            diagnostic(
                "outputs_saved",
                json_bytes=(
                    json_path.stat().st_size
                    if arguments.format in ("json", "both")
                    else None
                ),
                markdown_bytes=(
                    markdown_path.stat().st_size
                    if arguments.format in ("md", "both")
                    else None
                ),
            )
        outputs_written = True
        if arguments.archive_audio:
            emit_event(
                arguments.progress_json, "progress", phase="archiving", progress=0
            )
            with log_stage("archiving"):
                archive_audio(source, work_directory)
        diagnostic("job_finished", elapsed_seconds=time.monotonic() - started)
        emit_event(
            arguments.progress_json,
            "finished",
            progress=100,
            json_path=str(json_path) if arguments.format in ("json", "both") else None,
            markdown_path=(
                str(markdown_path) if arguments.format in ("md", "both") else None
            ),
        )
        if not arguments.progress_json:
            if arguments.format in ("json", "both"):
                print(json_path)
            if arguments.format in ("md", "both"):
                print(markdown_path)
        return 0
    except (OSError, ValueError, TranscriptionError) as error:
        diagnostic(
            "job_failed",
            "error",
            elapsed_seconds=time.monotonic() - started,
            traceback=traceback.format_exc(),
        )
        print(f"whisper: {error}", file=sys.stderr)
        return 1
    finally:
        if outputs_written or not has_output_backups(work_directory):
            shutil.rmtree(work_directory, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
