import argparse
import json
import os
import signal
import subprocess
import sys
import time
from types import FrameType

COMMON_FIELDS = {
    "agent_id",
    "agent_type",
    "cwd",
    "effort",
    "hook_event_name",
    "permission_mode",
    "prompt_id",
    "session_id",
    "transcript_path",
}

EVENT_FIELDS = {
    "Notification": {"message", "notification_type", "title"},
    "SessionStart": {"model", "session_title", "source"},
    "UserPromptSubmit": {"prompt", "session_title"},
    "PreToolUse": {"tool_input", "tool_name", "tool_use_id"},
    "PostToolUse": {
        "duration_ms",
        "tool_input",
        "tool_name",
        "tool_response",
        "tool_use_id",
    },
    "PreCompact": {"custom_instructions", "trigger"},
    "PostCompact": {"compact_summary", "trigger"},
    "Stop": {
        "background_tasks",
        "last_assistant_message",
        "session_crons",
        "stop_hook_active",
    },
    "SessionEnd": {"reason"},
}
SIGNAL_GRACE_SECONDS = 3


class ForwardedSignal(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def translate_hook_input(
    hook_input: object,
    event_name: str | None = None,
    notification_type: str | None = None,
    client: str = "Codex",
) -> dict[str, object]:
    if not isinstance(hook_input, dict):
        return {}

    target_event = event_name or str(hook_input.get("hook_event_name") or "")
    event_fields = EVENT_FIELDS.get(target_event, set())
    fields = COMMON_FIELDS | event_fields
    translated = {key: value for key, value in hook_input.items() if key in fields}
    if target_event:
        translated["hook_event_name"] = target_event

    turn_id = hook_input.get("turn_id")
    if "prompt_id" not in translated and isinstance(turn_id, str):
        translated["prompt_id"] = turn_id
    if target_event == "Notification" and notification_type is not None:
        translated.update(
            {
                "message": (
                    f"{client} is waiting for permission"
                    if notification_type == "permission_prompt"
                    else f"{client} is waiting for input"
                ),
                "notification_type": notification_type,
                "title": client,
            }
        )
    return translated


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("timeout must be positive")
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", required=True, type=positive_integer)
    parser.add_argument("--event")
    parser.add_argument("--notification-type")
    parser.add_argument("command")
    return parser.parse_args()


def terminate_process_group(process: subprocess.Popen[str], signum: int) -> None:
    if process.returncode is not None:
        return

    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def wait_after_signal(process: subprocess.Popen[str]) -> None:
    # Keep the leader unreaped so its PID cannot be reused during the group grace period.
    deadline = time.monotonic() + SIGNAL_GRACE_SECONDS
    while (remaining := deadline - time.monotonic()) > 0:
        time.sleep(remaining)

    terminate_process_group(process, signal.SIGKILL)
    process.communicate()


def run_command(command: str, hook_input: str, timeout: int) -> int:
    process = subprocess.Popen(
        ["/bin/sh", "-c", command],
        stdin=subprocess.PIPE,
        text=True,
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
            process.communicate(input=hook_input, timeout=timeout)
        except ForwardedSignal as forwarded:
            wait_after_signal(process)
            return 128 + forwarded.signum
        except subprocess.TimeoutExpired:
            terminate_process_group(process, signal.SIGTERM)
            wait_after_signal(process)
            return 124
        returncode = process.wait()
        return 128 - returncode if returncode < 0 else returncode
    finally:
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if process.returncode is None:
                terminate_process_group(process, signal.SIGTERM)
                wait_after_signal(process)
            if process.stdin is not None:
                process.stdin.close()
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)


def main() -> int:
    args = parse_args()

    try:
        hook_input = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        hook_input = {}

    client = os.environ.get("AI_AGENT_CLIENT", "Codex")
    translated = translate_hook_input(
        hook_input,
        event_name=args.event,
        notification_type=args.notification_type,
        client=client,
    )
    return run_command(args.command, json.dumps(translated), args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
