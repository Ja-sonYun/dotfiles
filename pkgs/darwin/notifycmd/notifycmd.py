import json
import subprocess
import sys


MAX_TITLE_LEN = 120
MAX_MESSAGE_LEN = 2000
NOTIFICATION_SOUNDS = {
    "agent-turn-complete": "Glass",
    "plan-mode-prompt": "Glass",
    "permission-request": "Funk",
    "user-action": "Funk",
    "user-input": "Funk",
}
APPLESCRIPT = (
    "on run argv\n"
    "    display notification (item 2 of argv) "
    "with title (item 1 of argv) sound name (item 3 of argv)\n"
    "end run"
)


def _sanitize_text(value: object, max_len: int) -> str:
    text = " ".join(str(value).split())
    if len(text) <= max_len:
        return text
    if max_len <= 3:
        return text[:max_len]
    return text[: max_len - 3] + "..."


def _coerce_input_messages(input_messages: list[object]) -> str:
    parts: list[str] = []
    for item in input_messages:
        if isinstance(item, str):
            parts.append(item)
            continue
        if isinstance(item, dict):
            if "content" in item:
                parts.append(str(item["content"]))
                continue
            if "text" in item:
                parts.append(str(item["text"]))
                continue
            parts.append(json.dumps(item, ensure_ascii=True))
            continue
        parts.append(str(item))
    return " ".join(parts)


def _notification_fields(
    notification: dict[str, object],
) -> tuple[str, str, str] | None:
    notification_type = notification.get("type")

    match notification_type:
        case "desktop-notification":
            title = notification.get("title", "")
            message = notification.get("message", "")
            sound = notification.get("sound", "")
        case "agent-turn-complete":
            assistant_message = notification.get("last-assistant-message")
            input_messages = notification.get("input-messages", [])
            message = (
                _coerce_input_messages(
                    input_messages if isinstance(input_messages, list) else []
                )
                or assistant_message
                or ""
            )
            title = (
                f"Codex: {assistant_message}"
                if assistant_message
                else "Codex: Turn Complete!"
            )
            sound = NOTIFICATION_SOUNDS[notification_type]
        case "permission-request":
            title = "Codex: Approval"
            message = notification.get("message", "Permission requested")
            sound = NOTIFICATION_SOUNDS[notification_type]
        case "plan-mode-prompt":
            title = "Codex: Plan Complete"
            message = notification.get("message", "Awaiting your input")
            sound = NOTIFICATION_SOUNDS[notification_type]
        case "user-action" | "user-input":
            title = "Codex: Action Required"
            message = notification.get("message", "Awaiting your input")
            sound = NOTIFICATION_SOUNDS[notification_type]
        case _:
            print(f"not sending a push notification for: {notification_type}")
            return None

    return (
        _sanitize_text(title, MAX_TITLE_LEN),
        _sanitize_text(message, MAX_MESSAGE_LEN),
        str(sound),
    )


def _main() -> int:
    if len(sys.argv) != 2:
        print("Usage: notifycmd <NOTIFICATION_JSON>")
        return 1

    try:
        notification = json.loads(sys.argv[1])
    except json.JSONDecodeError:
        return 1

    if not isinstance(notification, dict):
        return 1

    fields = _notification_fields(notification)
    if fields is None:
        return 0

    title, message, sound = fields
    subprocess.run(
        [
            "/usr/bin/osascript",
            "-e",
            APPLESCRIPT,
            "--",
            title,
            message,
            sound,
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    return 0


if __name__ == "__main__":
    sys.exit(_main())
