import argparse
import json
import os
import signal
import subprocess
import sys
import threading
from pathlib import Path
from types import FrameType
from typing import BinaryIO


INSTRUCTION_METHODS = {"initialize", "server/discover"}
RequestId = str | int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--instructions-file", required=True, type=Path)
    parser.add_argument("command")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    return parser.parse_args()


def parse_message(line: bytes) -> dict[str, object] | None:
    try:
        value = json.loads(line)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    return value if isinstance(value, dict) else None


def request_id(message: dict[str, object]) -> RequestId | None:
    value = message.get("id")
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return None
    return value


def forward_requests(
    source: BinaryIO,
    target: BinaryIO,
    pending: set[RequestId],
    lock: threading.Lock,
) -> None:
    try:
        for line in source:
            message = parse_message(line)
            if message is not None and message.get("method") in INSTRUCTION_METHODS:
                if (message_id := request_id(message)) is not None:
                    with lock:
                        pending.add(message_id)
            target.write(line)
            target.flush()
    except (BrokenPipeError, OSError):
        pass
    finally:
        try:
            target.close()
        except OSError:
            pass


def override_instructions(
    line: bytes,
    instructions: str,
    pending: set[RequestId],
    lock: threading.Lock,
) -> bytes:
    message = parse_message(line)
    if message is None or "method" in message:
        return line

    message_id = request_id(message)
    if message_id is None:
        return line

    with lock:
        if message_id not in pending:
            return line
        pending.remove(message_id)

    result = message.get("result")
    if not isinstance(result, dict):
        return line

    result["instructions"] = instructions
    return json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"


def forward_responses(
    source: BinaryIO,
    target: BinaryIO,
    instructions: str,
    pending: set[RequestId],
    lock: threading.Lock,
) -> None:
    for line in source:
        target.write(override_instructions(line, instructions, pending, lock))
        target.flush()


def terminate_process_group(process: subprocess.Popen[bytes], signum: int) -> None:
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def main() -> int:
    args = parse_args()
    try:
        instructions = args.instructions_file.read_text(encoding="utf-8")
        process = subprocess.Popen(
            [args.command, *args.arguments],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as error:
        print(error, file=sys.stderr)
        return 127

    assert process.stdin is not None
    assert process.stdout is not None

    pending: set[RequestId] = set()
    lock = threading.Lock()
    request_thread = threading.Thread(
        target=forward_requests,
        args=(sys.stdin.buffer, process.stdin, pending, lock),
        daemon=True,
    )
    request_thread.start()

    def forward_signal(signum: int, _frame: FrameType | None) -> None:
        terminate_process_group(process, signum)

    previous_handlers = {
        signum: signal.signal(signum, forward_signal)
        for signum in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        try:
            forward_responses(
                process.stdout,
                sys.stdout.buffer,
                instructions,
                pending,
                lock,
            )
        except (BrokenPipeError, OSError):
            terminate_process_group(process, signal.SIGTERM)
        return_code = process.wait()
        return 128 - return_code if return_code < 0 else return_code
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    raise SystemExit(main())
