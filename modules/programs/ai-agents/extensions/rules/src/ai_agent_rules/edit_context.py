import hashlib
import json
import time
from pathlib import Path

from ai_agent_hooks.edit_input import edit_targets
from ai_agent_hooks.hook_input import HookInput

from ai_agent_rules.code_changes import (
    MAX_SOURCE_BYTES,
    replacement_context,
    replacement_edits,
    source_text,
)
from ai_agent_rules.rule_files import read_json, write_json
from ai_agent_rules.sessions import session_key, state_lock


def context_path(directory: Path, hook_input: HookInput) -> Path:
    handle = session_key(hook_input)
    call = hook_input.get("tool_use_id")
    if handle is None or not isinstance(call, str) or not call:
        raise ValueError("replacement context requires a session and tool call ID")
    key = hashlib.sha256(call.encode()).hexdigest()
    return directory / f"{handle}.{key}.json"


def input_digest(hook_input: HookInput) -> str:
    value = [hook_input.get(key) for key in ("cwd", "tool_name", "tool_input")]
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def capture_context(hook_input: HookInput) -> None:
    tool = str(hook_input.get("tool_name") or "").rsplit(".", 1)[-1].lower()
    if tool not in {"edit", "multiedit", "edit_file"}:
        return
    with state_lock() as directory:
        directory = directory.parent / "edit-context"
        path = context_path(directory, hook_input)
        path.unlink(missing_ok=True)
        for previous in directory.glob("*.json"):
            if previous.stat().st_mtime < time.time() - 86400:
                previous.unlink(missing_ok=True)
        targets = edit_targets(hook_input)
        if len(targets) != 1:
            raise ValueError("replacement context requires one file")
        expected, texts = replacement_context(
            source_text(targets[0].before), hook_input.get("tool_input")
        )
        if sum(len(text.encode("utf-8")) for text in texts) > MAX_SOURCE_BYTES:
            raise ValueError("replacement context exceeds the 1 MiB inspection limit")
        write_json(
            path,
            {
                "input": input_digest(hook_input),
                "result": hashlib.sha256(expected.encode()).hexdigest(),
                "texts": texts,
            },
        )


def take_context(hook_input: HookInput, *, failed: bool = False) -> list[str] | None:
    """Consume a call's context, checking its result before any formatter runs.

    Failed calls discard their context without reading the edited file.
    Missing context returns None; mismatched or expired context raises ValueError.
    """
    tool = str(hook_input.get("tool_name") or "").rsplit(".", 1)[-1].lower()
    if tool not in {"edit", "multiedit", "edit_file"}:
        return None
    with state_lock() as directory:
        path = context_path(directory.parent / "edit-context", hook_input)
        try:
            if failed:
                return None
            try:
                if path.stat().st_mtime < time.time() - 86400:
                    raise ValueError("replacement context has expired")
                record = read_json(path)
            except FileNotFoundError:
                return None
        finally:
            path.unlink(missing_ok=True)
    if not isinstance(record, dict) or record.get("input") != input_digest(hook_input):
        raise ValueError("replacement context does not match this tool input")
    targets = edit_targets(hook_input)
    if len(targets) != 1:
        raise ValueError("replacement context requires one file")
    actual = source_text(targets[0].after)
    if record.get("result") != hashlib.sha256(actual.encode()).hexdigest():
        raise ValueError("actual edit differs from the captured replacement context")
    texts = record.get("texts")
    count = sum(
        bool(new) for _, new, _ in replacement_edits(hook_input.get("tool_input"))
    )
    if (
        not isinstance(texts, list)
        or len(texts) != count
        or any(not isinstance(text, str) for text in texts)
    ):
        raise ValueError("invalid replacement line context")
    return texts


def clear_context(hook_input: HookInput) -> None:
    handle = session_key(hook_input)
    if handle is not None:
        with state_lock() as directory:
            for path in (directory.parent / "edit-context").glob(f"{handle}.*.json"):
                path.unlink(missing_ok=True)
