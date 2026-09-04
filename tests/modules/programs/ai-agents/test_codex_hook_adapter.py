import json
import os
import runpy
import shlex
import signal
import subprocess
import sys
import unittest
from collections.abc import Callable
from pathlib import Path
from typing import cast
from unittest.mock import MagicMock, call, patch

HookInput = dict[str, object]
TranslateHookInput = Callable[[object, str | None, str | None, str], HookInput]
RunCommand = Callable[[str, str, int], int]

adapter_path = os.environ.get("AI_AGENTS_CODEX_HOOK_ADAPTER")
ADAPTER_PATH = (
    Path(adapter_path)
    if adapter_path
    else (
        Path(__file__).parents[4]
        / "modules"
        / "programs"
        / "ai-agents"
        / "hooks"
        / "codex_adapter.py"
    )
)
ADAPTER = runpy.run_path(str(ADAPTER_PATH))
TRANSLATE_HOOK_INPUT = cast(
    TranslateHookInput,
    ADAPTER["translate_hook_input"],
)
RUN_COMMAND = cast(RunCommand, ADAPTER["run_command"])


def run_adapter(
    hook_input: str,
    command: str,
    *,
    event: str | None = None,
    notification_type: str | None = None,
    timeout: int = 5,
) -> subprocess.CompletedProcess[str]:
    arguments = [
        sys.executable,
        str(ADAPTER_PATH),
        "--timeout",
        str(timeout),
    ]
    if event is not None:
        arguments.extend(["--event", event])
    if notification_type is not None:
        arguments.extend(["--notification-type", notification_type])
    arguments.extend(["--", command])
    return subprocess.run(
        arguments,
        input=hook_input,
        text=True,
        capture_output=True,
        check=False,
        env=os.environ | {"AI_AGENT_CLIENT": "Codex"},
    )


class TranslateHookInputTest(unittest.TestCase):
    def test_maps_codex_turn_id_to_claude_prompt_id(self) -> None:
        self.assertEqual(
            TRANSLATE_HOOK_INPUT(
                {
                    "agent_id": "agent-id",
                    "cwd": "/workspace",
                    "hook_event_name": "PreToolUse",
                    "model": "gpt-5",
                    "session_id": "session-id",
                    "tool_input": {"command": "true"},
                    "tool_name": "exec_command",
                    "tool_use_id": "tool-id",
                    "turn_id": "turn-id",
                },
                None,
                None,
                "Codex",
            ),
            {
                "agent_id": "agent-id",
                "cwd": "/workspace",
                "hook_event_name": "PreToolUse",
                "prompt_id": "turn-id",
                "session_id": "session-id",
                "tool_input": {"command": "true"},
                "tool_name": "exec_command",
                "tool_use_id": "tool-id",
            },
        )

    def test_keeps_claude_event_fields(self) -> None:
        self.assertEqual(
            TRANSLATE_HOOK_INPUT(
                {
                    "compact_summary": "summary",
                    "hook_event_name": "PostCompact",
                    "session_id": "session-id",
                    "trigger": "auto",
                },
                None,
                None,
                "Codex",
            ),
            {
                "compact_summary": "summary",
                "hook_event_name": "PostCompact",
                "session_id": "session-id",
                "trigger": "auto",
            },
        )

    def test_non_object_input_becomes_empty_object(self) -> None:
        self.assertEqual(TRANSLATE_HOOK_INPUT([], None, None, "Codex"), {})

    def test_translates_codex_notification_event(self) -> None:
        self.assertEqual(
            TRANSLATE_HOOK_INPUT(
                {
                    "cwd": "/workspace",
                    "hook_event_name": "PermissionRequest",
                    "session_id": "session-id",
                    "turn_id": "turn-id",
                },
                "Notification",
                "permission_prompt",
                "Codex",
            ),
            {
                "cwd": "/workspace",
                "hook_event_name": "Notification",
                "message": "Codex is waiting for permission",
                "notification_type": "permission_prompt",
                "prompt_id": "turn-id",
                "session_id": "session-id",
                "title": "Codex",
            },
        )

    def test_translates_codex_input_event(self) -> None:
        self.assertEqual(
            TRANSLATE_HOOK_INPUT(
                {
                    "hook_event_name": "PreToolUse",
                    "session_id": "session-id",
                    "tool_name": "request_user_input",
                    "tool_use_id": "tool-id",
                },
                "Notification",
                "elicitation_dialog",
                "Codex",
            ),
            {
                "hook_event_name": "Notification",
                "message": "Codex is waiting for input",
                "notification_type": "elicitation_dialog",
                "session_id": "session-id",
                "title": "Codex",
            },
        )


class MainTest(unittest.TestCase):
    def test_runs_command_with_translated_input(self) -> None:
        command = shlex.join(
            (
                sys.executable,
                "-c",
                (
                    "import json, os, sys; "
                    "json.dump({'client': os.environ['AI_AGENT_CLIENT'], "
                    "'input': json.load(sys.stdin)}, sys.stdout)"
                ),
            )
        )
        result = run_adapter(
            json.dumps(
                {
                    "hook_event_name": "UserPromptSubmit",
                    "prompt": "hello",
                    "turn_id": "turn-id",
                }
            ),
            command,
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "client": "Codex",
                "input": {
                    "hook_event_name": "UserPromptSubmit",
                    "prompt": "hello",
                    "prompt_id": "turn-id",
                },
            },
        )

    def test_returns_command_exit_code(self) -> None:
        command = shlex.join((sys.executable, "-c", "raise SystemExit(7)"))
        self.assertEqual(run_adapter("{}", command).returncode, 7)

    def test_timeout_kills_process_group(self) -> None:
        process = MagicMock()
        process.pid = 123
        process.communicate.side_effect = [
            subprocess.TimeoutExpired("test-hook", 1),
            (None, None),
        ]

        with (
            patch.object(subprocess, "Popen", return_value=process) as popen,
            patch.object(os, "killpg") as killpg,
        ):
            self.assertEqual(RUN_COMMAND("test-hook", "{}", 1), 124)

        popen.assert_called_once_with(
            ["/bin/sh", "-c", "test-hook"],
            stdin=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        killpg.assert_called_once_with(123, signal.SIGTERM)
        self.assertEqual(process.communicate.call_count, 2)

    def test_signal_is_forwarded_and_normalized(self) -> None:
        process = MagicMock()
        process.pid = 123
        handlers: dict[int, Callable[[int, object], None]] = {}

        def install_handler(
            signum: int,
            handler: Callable[[int, object], None],
        ) -> signal.Handlers:
            handlers[signum] = handler
            return signal.SIG_DFL

        def communicate(*_args: object, **_kwargs: object) -> tuple[None, None]:
            if process.communicate.call_count == 1:
                handlers[signal.SIGTERM](signal.SIGTERM, None)
            return None, None

        process.communicate.side_effect = communicate
        with (
            patch.object(subprocess, "Popen", return_value=process),
            patch.object(signal, "signal", side_effect=install_handler),
            patch.object(os, "killpg") as killpg,
        ):
            self.assertEqual(RUN_COMMAND("test-hook", "{}", 60), 143)

        killpg.assert_called_once_with(123, signal.SIGTERM)
        self.assertEqual(process.communicate.call_count, 2)

    def test_signal_kills_process_group_after_grace_period(self) -> None:
        process = MagicMock()
        process.pid = 123
        handlers: dict[int, Callable[[int, object], None]] = {}

        def install_handler(
            signum: int,
            handler: Callable[[int, object], None],
        ) -> signal.Handlers:
            handlers[signum] = handler
            return signal.SIG_DFL

        def communicate(*_args: object, **_kwargs: object) -> tuple[None, None]:
            if process.communicate.call_count == 1:
                handlers[signal.SIGTERM](signal.SIGTERM, None)
            if process.communicate.call_count == 2:
                raise subprocess.TimeoutExpired("test-hook", 1)
            return None, None

        process.communicate.side_effect = communicate
        with (
            patch.object(subprocess, "Popen", return_value=process),
            patch.object(signal, "signal", side_effect=install_handler),
            patch.object(os, "killpg") as killpg,
        ):
            self.assertEqual(RUN_COMMAND("test-hook", "{}", 60), 143)

        self.assertEqual(
            killpg.call_args_list,
            [call(123, signal.SIGTERM), call(123, signal.SIGKILL)],
        )
        self.assertEqual(process.communicate.call_count, 3)

    def test_repeated_signal_escalates_without_interrupting_cleanup(self) -> None:
        process = MagicMock()
        process.pid = 123
        handlers: dict[int, Callable[[int, object], None]] = {}

        def install_handler(
            signum: int,
            handler: Callable[[int, object], None],
        ) -> signal.Handlers:
            handlers[signum] = handler
            return signal.SIG_DFL

        def communicate(*_args: object, **_kwargs: object) -> tuple[None, None]:
            if process.communicate.call_count == 1:
                handlers[signal.SIGTERM](signal.SIGTERM, None)
            if process.communicate.call_count == 2:
                handlers[signal.SIGINT](signal.SIGINT, None)
            return None, None

        process.communicate.side_effect = communicate
        with (
            patch.object(subprocess, "Popen", return_value=process),
            patch.object(signal, "signal", side_effect=install_handler),
            patch.object(os, "killpg") as killpg,
        ):
            self.assertEqual(RUN_COMMAND("test-hook", "{}", 60), 143)

        self.assertEqual(
            killpg.call_args_list,
            [call(123, signal.SIGTERM), call(123, signal.SIGKILL)],
        )
        self.assertEqual(process.communicate.call_count, 2)

    def test_negative_command_exit_code_is_normalized(self) -> None:
        process = MagicMock()
        process.returncode = -signal.SIGTERM

        with patch.object(subprocess, "Popen", return_value=process):
            self.assertEqual(RUN_COMMAND("test-hook", "{}", 60), 143)

    def test_invalid_arguments_fail(self) -> None:
        result = subprocess.run(
            [sys.executable, str(ADAPTER_PATH)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
