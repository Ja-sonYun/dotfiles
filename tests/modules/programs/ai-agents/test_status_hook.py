import io
import json
import os
import runpy
import subprocess
import sys
import unittest
from collections.abc import Callable
from pathlib import Path
from typing import cast
from unittest.mock import patch

HookInput = dict[str, object]
StateForEvent = Callable[[HookInput, str], str | None]
Main = Callable[[], int]

hooks_dir = os.environ.get("AI_AGENTS_HOOKS_DIR")
HOOKS_DIR = (
    Path(hooks_dir)
    if hooks_dir
    else (
        Path(__file__).parents[4]
        / "shell"
        / "secrets"
        / "modules"
        / "home-manager"
        / "ai-agents"
        / "hooks"
    )
)
sys.path.insert(0, str(HOOKS_DIR))
STATUS = runpy.run_path(str(HOOKS_DIR / "status.py"))
STATE_FOR_EVENT = cast(StateForEvent, STATUS["state_for_event"])
MAIN = cast(Main, STATUS["main"])


class StateForEventTest(unittest.TestCase):
    def test_session_events(self) -> None:
        self.assertEqual(
            STATE_FOR_EVENT(
                {"hook_event_name": "SessionStart", "source": "resume"},
                "Codex",
            ),
            "idle",
        )
        for client in ("Claude", "Pi"):
            with self.subTest(client=client):
                self.assertEqual(
                    STATE_FOR_EVENT(
                        {"hook_event_name": "SessionStart", "source": "resume"},
                        client,
                    ),
                    "running",
                )
        self.assertEqual(
            STATE_FOR_EVENT({"hook_event_name": "SessionEnd"}, "Claude"),
            "idle",
        )

    def test_turn_events(self) -> None:
        for event_name in ("PostToolUse", "UserPromptSubmit"):
            with self.subTest(event_name=event_name):
                self.assertEqual(
                    STATE_FOR_EVENT({"hook_event_name": event_name}, "Pi"),
                    "running",
                )
        self.assertEqual(
            STATE_FOR_EVENT({"hook_event_name": "PreToolUse"}, "Codex"),
            "running",
        )
        self.assertEqual(
            STATE_FOR_EVENT({"hook_event_name": "Notification"}, "Codex"),
            "waiting",
        )

    def test_codex_input_tool_waits_for_notification_hook(self) -> None:
        for tool_name in (
            "request_user_input",
            "confirm_escalation",
            "_open_codex_api_key_setup",
        ):
            with self.subTest(tool_name=tool_name):
                self.assertIsNone(
                    STATE_FOR_EVENT(
                        {
                            "hook_event_name": "PreToolUse",
                            "tool_name": tool_name,
                        },
                        "Codex",
                    )
                )
        self.assertEqual(
            STATE_FOR_EVENT(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "request_user_input",
                },
                "Claude",
            ),
            "running",
        )

    def test_stop_state(self) -> None:
        self.assertEqual(
            STATE_FOR_EVENT({"hook_event_name": "Stop"}, "Pi"),
            "idle",
        )
        self.assertEqual(
            STATE_FOR_EVENT(
                {
                    "hook_event_name": "Stop",
                    "last_assistant_message": "<PROPOSED_PLAN>continue",
                },
                "Pi",
            ),
            "waiting",
        )

    def test_failure_and_unknown_events(self) -> None:
        for event_name in (
            "ElicitationResult",
            "PostToolUseFailure",
            "StopFailure",
            "Unknown",
        ):
            with self.subTest(event_name=event_name):
                self.assertIsNone(
                    STATE_FOR_EVENT({"hook_event_name": event_name}, "Claude")
                )


class MainTest(unittest.TestCase):
    def test_runs_status_command(self) -> None:
        hook_input = json.dumps(
            {
                "hook_event_name": "Notification",
                "notification_type": "permission_prompt",
            }
        )
        with (
            patch.dict(os.environ, {"AI_AGENT_CLIENT": "Codex"}),
            patch.object(sys, "argv", ["status.py", "status-command"]),
            patch.object(sys, "stdin", io.StringIO(hook_input)),
            patch.object(subprocess, "run") as run,
        ):
            self.assertEqual(MAIN(), 0)

        run.assert_called_once_with(
            ["status-command", "waiting"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def test_codex_input_tool_does_not_run_status_command(self) -> None:
        hook_input = json.dumps(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "request_user_input",
            }
        )
        with (
            patch.dict(os.environ, {"AI_AGENT_CLIENT": "Codex"}),
            patch.object(sys, "argv", ["status.py", "status-command"]),
            patch.object(sys, "stdin", io.StringIO(hook_input)),
            patch.object(subprocess, "run") as run,
        ):
            self.assertEqual(MAIN(), 0)

        run.assert_not_called()

    def test_invalid_arguments_or_missing_client_fail(self) -> None:
        with (
            patch.dict(os.environ, {"AI_AGENT_CLIENT": "Codex"}),
            patch.object(sys, "argv", ["status.py"]),
        ):
            self.assertEqual(MAIN(), 2)
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(sys, "argv", ["status.py", "status-command"]),
        ):
            self.assertEqual(MAIN(), 2)


if __name__ == "__main__":
    unittest.main()
