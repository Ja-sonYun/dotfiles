import argparse
import json
import os
import signal
import subprocess
import sys
from types import FrameType


class ForwardedSignal(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("timeout must be positive")
    return parsed


def restore_output(output: bytes) -> bytes:
    try:
        response = json.loads(output)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return output
    if not isinstance(response, dict):
        return output
    specific = response.get("hookSpecificOutput")
    if not isinstance(specific, dict) or specific.get("hookEventName") != "PostToolUse":
        return output
    specific["hookEventName"] = "PostToolUseFailure"
    return (json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8")


def terminate_process_group(process: subprocess.Popen[bytes], signum: int) -> None:
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def wait_after_signal(process: subprocess.Popen[bytes]) -> bytes:
    try:
        output, _ = process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    finally:
        terminate_process_group(process, signal.SIGKILL)
    output, _ = process.communicate()
    return output


def run_command(command: str, hook_input: bytes, timeout: int | None) -> int:
    process = subprocess.Popen(
        ["/bin/sh", "-c", command],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        start_new_session=True,
    )
    signal_forwarded = False

    def forward_signal(signum: int, _frame: FrameType | None) -> None:
        nonlocal signal_forwarded
        if signal_forwarded:
            terminate_process_group(process, signal.SIGKILL)
            return
        signal_forwarded = True
        terminate_process_group(process, signum)
        raise ForwardedSignal(signum)

    previous_handlers = {
        signum: signal.signal(signum, forward_signal)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    try:
        try:
            output, _ = process.communicate(input=hook_input, timeout=timeout)
            returncode = process.wait()
            exit_code = 128 - returncode if returncode < 0 else returncode
        except ForwardedSignal as forwarded:
            output = wait_after_signal(process)
            exit_code = 128 + forwarded.signum
        except subprocess.TimeoutExpired:
            terminate_process_group(process, signal.SIGTERM)
            output = wait_after_signal(process)
            exit_code = 124
    finally:
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if process.poll() is None:
                terminate_process_group(process, signal.SIGKILL)
                process.communicate()
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)

    sys.stdout.buffer.write(restore_output(output))
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=positive_integer)
    parser.add_argument("command")
    args = parser.parse_args()

    try:
        hook_input = json.loads(sys.stdin.buffer.read() or b"{}")
    except (json.JSONDecodeError, UnicodeDecodeError):
        print("Invalid post-tool hook input: expected a JSON object.", file=sys.stderr)
        return 1
    if not isinstance(hook_input, dict):
        print("Invalid post-tool hook input: expected a JSON object.", file=sys.stderr)
        return 1

    translated = {
        **hook_input,
        "hook_event_name": "PostToolUse",
        "tool_failed": True,
    }
    try:
        return run_command(
            args.command,
            json.dumps(translated).encode("utf-8"),
            args.timeout,
        )
    except OSError as error:
        print(f"Post-tool hook adapter failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
