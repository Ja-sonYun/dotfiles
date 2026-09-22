import json
import subprocess
import sys

MAX_TITLE_LEN = 120
MAX_MESSAGE_LEN = 2000
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


def _notification_fields(
    notification: dict[str, object],
) -> tuple[str, str, str] | None:
    notification_type = notification.get("type")

    if notification_type != "desktop-notification":
        print(f"not sending a push notification for: {notification_type}")
        return None

    return (
        _sanitize_text(notification.get("title", ""), MAX_TITLE_LEN),
        _sanitize_text(notification.get("message", ""), MAX_MESSAGE_LEN),
        str(notification.get("sound", "")),
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
