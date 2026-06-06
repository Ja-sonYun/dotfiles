#!/usr/bin/env python3

import json
import shutil
import subprocess
import sys


MAX_TITLE_LEN = 120
MAX_MESSAGE_LEN = 2000
NOTIFICATION_SOUNDS = {
    "agent-turn-complete": "Glass",
    "permission-request": "Funk",
}


def _sanitize_text(value: str, max_len: int) -> str:
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


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: notify.py <NOTIFICATION_JSON>")
        return 1

    try:
        notification = json.loads(sys.argv[1])
    except json.JSONDecodeError:
        return 1

    match notification_type := notification.get("type"):
        case "agent-turn-complete":
            assistant_message = notification.get("last-assistant-message")
            input_messages = notification.get("input-messages", [])
            message = _coerce_input_messages(input_messages)
            if assistant_message:
                title = f"Codex: {assistant_message}"
            else:
                title = "Codex: Turn Complete!"
        case "permission-request":
            assistant_message = None
            title = "Codex: Approval"
            message = notification.get("message", "Permission requested")
        case _:
            print(f"not sending a push notification for: {notification_type}")
            return 0

    thread_id = notification.get("thread-id", "")

    if shutil.which("terminal-notifier") is None:
        return 0

    title = _sanitize_text(title, MAX_TITLE_LEN)
    message = _sanitize_text(message or assistant_message or "", MAX_MESSAGE_LEN)

    subprocess.run(
        [
            "terminal-notifier",
            "-title",
            title,
            "-message",
            message,
            "-sound",
            NOTIFICATION_SOUNDS[notification_type],
            "-group",
            "codex-" + str(thread_id),
            "-ignoreDnD",
            "-activate",
            "com.googlecode.iterm2",
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
