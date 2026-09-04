import json
import os
import subprocess
import sys

from hook_input import HookInput, is_proposed_plan, load_hook_input


def notification_for_event(
    hook_input: HookInput,
    client: str,
) -> dict[str, str] | None:
    event_name = str(hook_input.get("hook_event_name") or "")
    if event_name == "Stop":
        if is_proposed_plan(hook_input):
            return {
                "type": "desktop-notification",
                "title": f"{client}: Action Required",
                "message": "Awaiting your input",
                "sound": "Funk",
            }
        return {
            "type": "desktop-notification",
            "title": f"{client}: Turn Complete",
            "message": "Done",
            "sound": "Glass",
        }
    if event_name == "Notification":
        notification_type = str(hook_input.get("notification_type") or "")
        if notification_type == "permission_prompt":
            return {
                "type": "desktop-notification",
                "title": f"{client}: Approval",
                "message": "Permission requested",
                "sound": "Funk",
            }
        if notification_type in {"elicitation_dialog", "idle_prompt"}:
            return {
                "type": "desktop-notification",
                "title": f"{client}: Action Required",
                "message": "Awaiting your input",
                "sound": "Funk",
            }
    return None


def run_notification(command: str, notification: dict[str, str]) -> None:
    subprocess.run(
        [command, json.dumps(notification)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main() -> int:
    client = os.environ.get("AI_AGENT_CLIENT")
    if len(sys.argv) != 2 or not client:
        return 2

    hook_input = load_hook_input(sys.stdin.read())
    notification = notification_for_event(hook_input, client)
    if notification is not None:
        run_notification(sys.argv[1], notification)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
