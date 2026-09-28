import fcntl
import os
import re
import time
from pathlib import Path
from uuid import uuid4

from ai_agent_rules.context import environment, write_output
from ai_agent_rules.rule_files import write_json


def save_log(path: Path | None, data: dict[str, object]) -> None:
    if path is None:
        return
    try:
        write_json(path, data)
    except (OSError, TypeError, ValueError) as error:
        write_output(f"[Rules debug log failed] {error}\n", error=True)


def cleanup_logs(directory: Path) -> None:
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (directory / ".cleanup").open("a+") as marker:
        try:
            fcntl.flock(marker, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return

        now = time.time()
        status = os.fstat(marker.fileno())
        if status.st_size and now - status.st_mtime < 86400:
            return

        cutoff = now - 7 * 86400
        for previous in directory.glob("*/*.json"):
            if previous.stat().st_mtime < cutoff:
                previous.unlink()

        marker.truncate(0)
        marker.write("1")
        marker.flush()


def start_log(
    enabled: bool, handle: str | None, data: dict[str, object]
) -> Path | None:
    if not enabled:
        return None
    cache = Path(environment().get("XDG_CACHE_HOME") or Path.home() / ".cache")
    directory = cache / "ai-agent" / "rules" / "logs"
    name = handle if handle and re.fullmatch(r"[0-9a-f]{64}", handle) else "unscoped"
    path = directory / name / f"{uuid4().hex}.json"
    try:
        cleanup_logs(directory)
    except OSError as error:
        write_output(f"[Rules log cleanup failed] {error}\n", error=True)
    save_log(path, data)
    return path
