#!@PYTHON@
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
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

_active_process: subprocess.Popen[str] | None = None
_process_starting = False
_pending_termination_signal: int | None = None


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


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Transcribe audio locally with whisper.cpp large-v3."
    )
    parser.add_argument("input", type=Path, help="Audio or video file to transcribe")
    parser.add_argument(
        "--meeting",
        action="store_true",
        help="Treat audio stream 1 as Remote and stream 2 as You",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output base path without .json or .md",
    )
    parser.add_argument("--language", default="auto", help="Whisper language code")
    parser.add_argument("--progress-json", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args()


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


def parse_start_ms(value: object) -> int:
    if not isinstance(value, (int, float, str)) or isinstance(value, bool):
        return 0
    try:
        return round(float(value) * 1000)
    except ValueError:
        return 0


def probe_audio_streams(source: Path) -> list[AudioStream]:
    result = subprocess.run(
        [
            FFPROBE,
            "-v",
            "error",
            "-select_streams",
            "a",
            "-show_entries",
            "stream=index,start_time",
            "-of",
            "json",
            str(source),
        ],
        check=False,
        capture_output=True,
        text=True,
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
    return streams


def extract_audio(source: Path, stream: AudioStream, destination: Path) -> None:
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
    if result.returncode != 0:
        message = result.stderr.strip().splitlines()
        raise TranscriptionError(message[-1] if message else "Could not extract audio")


def whisper_error(lines: list[str]) -> str:
    useful = [
        line.strip()
        for line in lines
        if line.strip() and "progress =" not in line
    ]
    return useful[-1] if useful else "whisper-cli exited with an error"


def run_whisper(
    audio_path: Path,
    output_base: Path,
    language: str,
    phase: str,
    progress_start: int,
    progress_end: int,
    progress_json: bool,
) -> dict[str, Any]:
    global _active_process, _pending_termination_signal, _process_starting

    process: subprocess.Popen[str] | None = None
    try:
        _process_starting = True
        try:
            process = subprocess.Popen(
                [
                    WHISPER_CLI,
                    "-m",
                    WHISPER_MODEL,
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
    return payload


def timestamp_ms(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    match = re.search(r"(\d+):(\d+):(\d+)[,.](\d+)", value)
    if not match:
        return None
    hours, minutes, seconds, fraction = match.groups()
    milliseconds = int(fraction[:3].ljust(3, "0"))
    return (
        ((int(hours) * 60 + int(minutes)) * 60 + int(seconds)) * 1000
        + milliseconds
    )


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


def is_microphone_echo(microphone: dict[str, Any], system: dict[str, Any]) -> bool:
    microphone_text = normalized_text(microphone["text"])
    system_text = normalized_text(system["text"])
    if min(len(microphone_text), len(system_text)) < 20:
        return False
    if abs(microphone["start_ms"] - system["start_ms"]) > 1500:
        return False

    overlap = min(microphone["end_ms"], system["end_ms"]) - max(
        microphone["start_ms"], system["start_ms"]
    )
    shortest = min(
        microphone["end_ms"] - microphone["start_ms"],
        system["end_ms"] - system["start_ms"],
    )
    if shortest <= 0 or overlap / shortest < 0.65:
        return False
    return SequenceMatcher(None, microphone_text, system_text).ratio() >= 0.92


def merged_segments(results: list[TrackResult]) -> list[dict[str, Any]]:
    segments = sorted(
        (segment for result in results for segment in result.segments),
        key=lambda segment: (
            segment["start_ms"],
            segment["end_ms"],
            segment["channel"],
        ),
    )
    system_segments = [
        segment for segment in segments if segment["channel"] == "system"
    ]
    merged: list[dict[str, Any]] = []
    system_start = 0
    for segment in segments:
        if segment["channel"] == "microphone":
            while (
                system_start < len(system_segments)
                and system_segments[system_start]["end_ms"]
                < segment["start_ms"] - 1500
            ):
                system_start += 1
            duplicate = False
            for candidate in system_segments[system_start:]:
                if candidate["start_ms"] > segment["end_ms"] + 1500:
                    break
                if is_microphone_echo(segment, candidate):
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
) -> str:
    speakers = ", ".join(
        f"{result.speaker} = {result.channel}" for result in results
    )
    lines = [
        "# Transcript",
        "",
        f"- Source: {source.name}",
        "- Model: Whisper large-v3",
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
) -> None:
    payload = {
        "schema_version": 1,
        "source_file": source.name,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
            "+00:00", "Z"
        ),
        "engine": {
            "name": "whisper.cpp",
            "model": "large-v3",
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
    temporary_json.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary_markdown.write_text(
        render_markdown(source, results, segments),
        encoding="utf-8",
    )
    replace_output_pair(
        [
            (temporary_json, json_path),
            (temporary_markdown, markdown_path),
        ],
        work_directory,
    )


def transcribe_track(
    source: Path,
    stream: AudioStream,
    common_start_ms: int,
    channel: str,
    speaker: str,
    language: str,
    phase: str,
    progress_start: int,
    progress_end: int,
    progress_json: bool,
    work_directory: Path,
) -> TrackResult:
    audio_path = work_directory / f"{channel}.wav"
    whisper_output = work_directory / f"{channel}-whisper"
    extract_audio(source, stream, audio_path)
    payload = run_whisper(
        audio_path,
        whisper_output,
        language,
        phase,
        progress_start,
        progress_end,
        progress_json,
    )
    start_offset_ms = max(0, stream.start_ms - common_start_ms)
    return TrackResult(
        channel=channel,
        speaker=speaker,
        stream_index=stream.index,
        start_offset_ms=start_offset_ms,
        language=detected_language(payload),
        segments=parse_segments(payload, channel, speaker, start_offset_ms),
    )


def transcribe(
    source: Path,
    meeting: bool,
    language: str,
    progress_json: bool,
    work_directory: Path,
) -> list[TrackResult]:
    streams = probe_audio_streams(source)
    common_start_ms = min(stream.start_ms for stream in streams)
    if not meeting:
        return [
            transcribe_track(
                source,
                streams[0],
                common_start_ms,
                "audio",
                "Audio",
                language,
                "audio",
                0,
                100,
                progress_json,
                work_directory,
            )
        ]
    if len(streams) < 2:
        raise TranscriptionError(
            "Meeting recording must contain system and microphone audio"
        )

    system_stream, microphone_stream = streams[:2]
    microphone = transcribe_track(
        source,
        microphone_stream,
        common_start_ms,
        "microphone",
        "You",
        language,
        "You",
        0,
        50,
        progress_json,
        work_directory,
    )
    system = transcribe_track(
        source,
        system_stream,
        common_start_ms,
        "system",
        "Remote",
        language,
        "Remote",
        50,
        100,
        progress_json,
        work_directory,
    )
    return [microphone, system]


def main() -> int:
    install_signal_handlers()
    arguments = parse_arguments()
    source = arguments.input.expanduser().resolve()
    if not source.is_file():
        print(f"whisper: input file not found: {source}", file=sys.stderr)
        return 1

    json_path, markdown_path = output_paths(source, arguments.output)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    work_root = json_path.parent / ".tmp"
    cleanup_stale_work_directories(work_root)
    work_directory = work_root / f"whisper-{os.getpid()}-{time.time_ns()}"
    outputs_written = False
    try:
        work_directory.mkdir(parents=True)
        emit_event(arguments.progress_json, "progress", phase="preparing", progress=0)
        results = transcribe(
            source,
            arguments.meeting,
            arguments.language,
            arguments.progress_json,
            work_directory,
        )
        segments = merged_segments(results)
        write_outputs(
            source,
            results,
            segments,
            json_path,
            markdown_path,
            work_directory,
        )
        outputs_written = True
        emit_event(
            arguments.progress_json,
            "finished",
            progress=100,
            json_path=str(json_path),
            markdown_path=str(markdown_path),
        )
        if not arguments.progress_json:
            print(json_path)
            print(markdown_path)
        return 0
    except (OSError, ValueError, TranscriptionError) as error:
        print(f"whisper: {error}", file=sys.stderr)
        return 1
    finally:
        if outputs_written or not has_output_backups(work_directory):
            shutil.rmtree(work_directory, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
