import json
import subprocess

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import ToolAnnotations

INSTRUCTIONS = """Use notify to keep the user informed during the current task.
Notify at the start, meaningful step transitions, and completion or interruption.
Do not notify for every tool call or repeat unchanged progress.
Use concise text in the user's language describing the task and current step.
Distinguish successful completion from failure, cancellation, and waiting for input.
Only report work actually performed; notifications do not authorize additional work.
The tool requests a desktop notification; it does not confirm that it was displayed
or read by the user.
"""


def notify(
    text: str,
    title: str = "AI Agent",
    sound: str = "Frog",
) -> dict[str, str]:
    if not text.strip():
        raise ToolError("Notification text must not be empty.")

    payload = json.dumps(
        {
            "type": "desktop-notification",
            "title": title,
            "message": text,
            "sound": sound,
        },
        ensure_ascii=False,
    )
    try:
        subprocess.run(
            ["notifycmd", payload],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ToolError("Could not request the desktop notification.") from error

    return {"status": "requested"}


def main() -> None:
    server = FastMCP("notify", instructions=INSTRUCTIONS, log_level="ERROR")
    server.tool(
        name="notify",
        description=(
            "Request a desktop notification with a concise task progress update, "
            "an optional title (default: AI Agent), and sound (default: Frog). "
            "Display duration and sound playback depend on macOS notification settings."
        ),
        annotations=ToolAnnotations(
            readOnlyHint=False,
            destructiveHint=False,
            idempotentHint=False,
            openWorldHint=False,
        ),
    )(notify)
    server.run(transport="stdio")
