import asyncio
import json
import os
import signal
from typing import Any, Literal

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations


async def run(arguments: list[str], *, write: bool = False) -> Any:
    executable = os.environ["CALENDAR_EXECUTABLE"]
    process = await asyncio.create_subprocess_exec(
        executable,
        "--output",
        "json",
        *arguments,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )
    pending = asyncio.create_task(process.communicate())
    try:
        async with asyncio.timeout(120):
            stdout, stderr = await asyncio.shield(pending)
    except (TimeoutError, asyncio.CancelledError):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        await asyncio.sleep(1)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await asyncio.shield(pending)
        raise
    if process.returncode:
        raise ToolError(stderr.decode(errors="replace").strip())
    output = stdout.decode()
    if write:
        return {"status": "completed", "output": output}
    try:
        return json.loads(output)
    except json.JSONDecodeError as error:
        raise ToolError("Calendar returned invalid JSON.") from error


def flags(values: dict[str, str | bool | int | list[str] | None]) -> list[str]:
    result = []
    for name, value in values.items():
        if value is None:
            continue
        entries = value if isinstance(value, list) else [value]
        for entry in entries:
            text = str(entry).lower() if isinstance(entry, bool) else str(entry)
            result.append(f"--{name.replace('_', '-')}={text}")
    return result


async def list_calendars() -> Any:
    """List available Apple calendars to identify a calendar before querying events."""
    return await run(["calendars", "list"])


async def list_events(start: str, end: str, calendar_id: str | None = None) -> Any:
    """List Apple Calendar events in a date range, optionally limited to one calendar."""
    return await run(
        ["list", "--from", start, "--to", end, *flags({"calendar_id": calendar_id})]
    )


async def search_events(query: str, start: str, end: str, limit: int = 100) -> Any:
    """Search Apple Calendar events by text within a date range, up to the given limit."""
    return await run(
        ["search", "--from", start, "--to", end, "--limit", str(limit), "--", query]
    )


async def get_event(event_id: str) -> Any:
    """Read an Apple Calendar event using an ID returned by listing or searching events."""
    return await run(["show", "--id", event_id])


async def create_event(
    title: str,
    start: str,
    calendar: str,
    end: str | None = None,
    all_day: bool = False,
    timezone: str | None = None,
    location: str | None = None,
    notes: str | None = None,
    alert: list[str] | None = None,
    repeat: Literal["daily", "weekly", "monthly", "yearly"] | None = None,
    repeat_interval: int = 1,
    repeat_until: str | None = None,
    repeat_count: int | None = None,
    repeat_days: str | None = None,
) -> Any:
    """Create an Apple Calendar event with optional alerts and recurrence.

    Recurrence details require an explicit daily, weekly, monthly, or yearly repeat.
    """
    if repeat is None and (
        repeat_interval != 1
        or any(value is not None for value in (repeat_until, repeat_count, repeat_days))
    ):
        raise ToolError(
            "Recurrence details require repeat=daily, weekly, monthly, or yearly."
        )
    return await run(["add", *flags(locals())], write=True)


async def update_event(
    event_id: str,
    span: Literal["this", "future"],
    title: str | None = None,
    start: str | None = None,
    end: str | None = None,
    calendar: str | None = None,
    all_day: bool | None = None,
    timezone: str | None = None,
    location: str | None = None,
    notes: str | None = None,
    alert: list[str] | None = None,
    repeat: Literal["none", "daily", "weekly", "monthly", "yearly"] | None = None,
    repeat_interval: int | None = None,
    repeat_until: str | None = None,
    repeat_count: int | None = None,
    repeat_days: str | None = None,
) -> Any:
    """Update an event; recurrence details require an explicit non-'none' repeat type.

    Omit alert to retain alarms, pass [] to remove them, or a list to replace them.
    """
    if any(
        value is not None
        for value in (repeat_interval, repeat_until, repeat_count, repeat_days)
    ) and repeat in (None, "none"):
        raise ToolError(
            "Recurrence details require repeat=daily, weekly, monthly, or yearly."
        )
    values = locals().copy()
    values.pop("event_id")
    if alert == []:
        values["alert"] = ["none"]
    return await run(["update", "--id", event_id, *flags(values)], write=True)


async def delete_event(event_id: str, span: Literal["this", "future", "all"]) -> Any:
    """Delete an Apple Calendar event with an explicit recurrence scope.

    Use this for one occurrence, future for this and following occurrences,
    or all for the entire recurring series.
    """
    return await run(
        ["delete", "--id", event_id, "--span", span, "--force"], write=True
    )


async def create_calendar(title: str, source: str, color: str | None = None) -> Any:
    """Create an Apple calendar in the specified source, optionally setting its color."""
    return await run(["calendars", "create", *flags(locals())], write=True)


async def update_calendar(
    name: str, title: str | None = None, color: str | None = None
) -> Any:
    """Rename an Apple calendar or change its color, selecting it by its current name."""
    return await run(
        ["calendars", "update", *flags({"title": title, "color": color}), "--", name],
        write=True,
    )


async def delete_calendar(name: str) -> Any:
    """Delete the named Apple calendar and its events."""
    return await run(["calendars", "delete", "--force", "--", name], write=True)


def main() -> None:
    server = FastMCP(
        "apple-calendar",
        host="127.0.0.1",
        port=7363,
        stateless_http=True,
        json_response=True,
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=["127.0.0.1:*", "localhost:*"],
            allowed_origins=[],
        ),
    )
    for tool in (list_calendars, list_events, search_events, get_event):
        server.tool(annotations=ToolAnnotations(readOnlyHint=True))(tool)
    for tool in (
        create_event,
        update_event,
        delete_event,
        create_calendar,
        update_calendar,
        delete_calendar,
    ):
        server.tool(
            annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=True)
        )(tool)
    server.run(transport="streamable-http")
