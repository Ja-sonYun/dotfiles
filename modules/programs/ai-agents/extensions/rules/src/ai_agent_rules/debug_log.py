import os
import re
import sys
import time
from pathlib import Path
from uuid import uuid4

from ai_agent_rules.rule_files import write_json


def save_log(path: Path | None, data: dict[str, object]) -> None:
    if path is None:
        return
    try:
        write_json(path, data)
    except (OSError, TypeError, ValueError) as error:
        print(f"[Rules debug log failed] {error}", file=sys.stderr)


def start_log(
    enabled: bool, handle: str | None, data: dict[str, object]
) -> Path | None:
    if not enabled:
        return None
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    directory = cache / "ai-agent" / "rules" / "logs"
    name = handle if handle and re.fullmatch(r"[0-9a-f]{64}", handle) else "unscoped"
    path = directory / name / f"{uuid4().hex}.json"
    try:
        cutoff = time.time() - 7 * 86400
        for previous in directory.glob("*/*.json"):
            if previous.stat().st_mtime < cutoff:
                previous.unlink()
    except OSError as error:
        print(f"[Rules log cleanup failed] {error}", file=sys.stderr)
    save_log(path, data)
    return path
