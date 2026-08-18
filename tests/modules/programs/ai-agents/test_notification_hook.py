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
NotificationForEvent = Callable[[HookInput, str], dict[str, str] | None]
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
NOTIFICATION = runpy.run_path(str(HOOKS_DIR / "notification.py"))
NOTIFICATION_FOR_EVENT = cast(
    NotificationForEvent,
    NOTIFICATION["notification_for_event"],
)
MAIN = cast(Main, NOTIFICATION["main"])


class NotificationForEventTest(unittest.TestCase):
    def test_stop_notifications(self) -> None:
        self.assertEqual(
            NOTIFICATION_FOR_EVENT({"hook_event_name": "Stop"}, "Claude"),
            {
                "type": "desktop-notification",
                "title": "Claude: Turn Complete",
                "message": "Done",
                "sound": "Glass",
            },
        )
        self.assertEqual(
            NOTIFICATION_FOR_EVENT(
                {
                    "hook_event_name": "Stop",
                    "last_assistant_message": "<proposed_plan>continue",
                },
                "Claude",
            ),
            {
                "type": "desktop-notification",
                "title": "Claude: Action Required",
                "message": "Awaiting your input",
                "sound": "Funk",
            },
        )

    def test_notification_events(self) -> None:
        expectations = {
            "permission_prompt": {
                "type": "desktop-notification",
                "title": "Codex: Approval",
                "message": "Permission requested",
                "sound": "Funk",
            },
            "elicitation_dialog": {
                "type": "desktop-notification",
                "title": "Codex: Action Required",
                "message": "Awaiting your input",
                "sound": "Funk",
            },
            "idle_prompt": {
                "type": "desktop-notification",
                "title": "Codex: Action Required",
                "message": "Awaiting your input",
                "sound": "Funk",
            },
        }
        for notification_type, expected in expectations.items():
            with self.subTest(notification_type=notification_type):
                self.assertEqual(
                    NOTIFICATION_FOR_EVENT(
                        {
                            "hook_event_name": "Notification",
                            "notification_type": notification_type,
                        },
                        "Codex",
                    ),
                    expected,
                )

    def test_other_events_are_ignored(self) -> None:
        self.assertIsNone(
            NOTIFICATION_FOR_EVENT(
                {
                    "hook_event_name": "Notification",
                    "notification_type": "unknown",
                },
                "Pi",
            )
        )


class MainTest(unittest.TestCase):
    def test_runs_notification_command(self) -> None:
        expected = {
            "type": "desktop-notification",
            "title": "Pi: Turn Complete",
            "message": "Done",
            "sound": "Glass",
        }
        with (
            patch.dict(os.environ, {"AI_AGENT_CLIENT": "Pi"}),
            patch.object(sys, "argv", ["notification.py", "notify-command"]),
            patch.object(
                sys,
                "stdin",
                io.StringIO(json.dumps({"hook_event_name": "Stop"})),
            ),
            patch.object(subprocess, "run") as run,
        ):
            self.assertEqual(MAIN(), 0)

        run.assert_called_once_with(
            ["notify-command", json.dumps(expected)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def test_ignored_event_does_not_run_notification_command(self) -> None:
        with (
            patch.dict(os.environ, {"AI_AGENT_CLIENT": "Pi"}),
            patch.object(sys, "argv", ["notification.py", "notify-command"]),
            patch.object(
                sys,
                "stdin",
                io.StringIO(
                    json.dumps(
                        {
                            "hook_event_name": "Notification",
                            "notification_type": "unknown",
                        }
                    )
                ),
            ),
            patch.object(subprocess, "run") as run,
        ):
            self.assertEqual(MAIN(), 0)

        run.assert_not_called()

    def test_invalid_arguments_or_missing_client_fail(self) -> None:
        with (
            patch.dict(os.environ, {"AI_AGENT_CLIENT": "Pi"}),
            patch.object(sys, "argv", ["notification.py"]),
        ):
            self.assertEqual(MAIN(), 2)
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(sys, "argv", ["notification.py", "notify-command"]),
        ):
            self.assertEqual(MAIN(), 2)


if __name__ == "__main__":
    unittest.main()
