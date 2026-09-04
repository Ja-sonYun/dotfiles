import hashlib
import json
import os
import re
import sys
from collections.abc import MutableMapping, MutableSequence
from pathlib import Path
from typing import Any

import tomlkit
from tomlkit.items import AoT, Table


GENERATED_COMMENT = "nix-generated"
CONTAINER_COMMENT = "nix-generated-container"


def _read(path: Path) -> str:
    return path.read_text() if path.exists() else ""


def _write_atomic(path: Path, text: str) -> None:
    temporary = path.with_name(f"{path.name}.hm-tmp")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
        0o600,
    )
    with os.fdopen(descriptor, "w") as file:
        file.write(text)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def _resolve_secrets(value: Any) -> Any:
    if isinstance(value, MutableMapping):
        if "_secret" in value:
            if list(value) != ["_secret"] or not isinstance(value["_secret"], str):
                raise ValueError("invalid _secret value")
            secret = Path(value["_secret"]).read_text()
            return secret.removesuffix("\n").removesuffix("\r")
        for key in list(value):
            value[key] = _resolve_secrets(value[key])
    elif isinstance(value, MutableSequence):
        for index, item in enumerate(value):
            value[index] = _resolve_secrets(item)
    return value


def _has_comment(value: Any, comment: str) -> bool:
    trivia = getattr(value, "trivia", None)
    return trivia is not None and trivia.comment.strip() == f"# {comment}"


def _clear_comment(value: Any) -> None:
    value.trivia.comment = ""
    value.trivia.comment_ws = ""


def _item(document: MutableMapping[str, Any], key: str) -> Any:
    item = getattr(document, "item", None)
    return item(key) if item is not None else document[key]


def _mark_generated(value: Any) -> None:
    if isinstance(value, Table):
        if value:
            for key in value:
                _mark_generated(_item(value, key))
        else:
            value.comment(CONTAINER_COMMENT)
    elif isinstance(value, AoT):
        for table in value:
            table.comment(GENERATED_COMMENT)
    else:
        value.comment(GENERATED_COMMENT)


def _is_generated(value: Any) -> bool:
    if isinstance(value, Table):
        return False
    if isinstance(value, AoT):
        return any(_has_comment(table, GENERATED_COMMENT) for table in value)
    return _has_comment(value, GENERATED_COMMENT)


def _remove_generated(document: MutableMapping[str, Any]) -> None:
    for key in list(document):
        value = _item(document, key)
        if _is_generated(value):
            document.pop(key)
            continue
        if not isinstance(value, Table):
            continue

        _remove_generated(value)
        if not _has_comment(value, CONTAINER_COMMENT):
            continue
        if value:
            _clear_comment(value)
        else:
            document.pop(key)


def _merge_generated(
    document: MutableMapping[str, Any],
    fragment: MutableMapping[str, Any],
) -> None:
    for key in fragment:
        value = _item(fragment, key)
        if isinstance(value, Table) and not _is_generated(value):
            current = document.get(key)
            if not isinstance(current, Table):
                document.pop(key, None)
                current = tomlkit.table()
                current.comment(CONTAINER_COMMENT)
                document[key] = current
            _merge_generated(current, value)
        else:
            document.pop(key, None)
            document[key] = value


def _add_hook_state(fragment: Any, target: Path) -> None:
    hooks = fragment.get("hooks")
    if hooks is None:
        return
    if not isinstance(hooks, MutableMapping):
        raise ValueError("hooks must be a table")

    hooks.pop("state", None)
    state = {}
    for event, blocks in hooks.items():
        if not isinstance(blocks, MutableSequence):
            raise ValueError(f"hooks.{event} must be an array")
        event_name = re.sub(r"(?<!^)(?=[A-Z])", "_", event).lower()
        for index, block in enumerate(blocks):
            if not isinstance(block, MutableMapping):
                raise ValueError(f"hooks.{event}[{index}] must be a table")
            commands = block.get("hooks")
            if not isinstance(commands, MutableSequence):
                raise ValueError(f"hooks.{event}[{index}].hooks must be an array")

            normalized = []
            for command in commands:
                value = command.unwrap()
                value["timeout"] = value.get("timeout", 600)
                value["async"] = value.get("async", False)
                normalized.append(value)

            trusted_input = {
                "event_name": event_name,
                "hooks": normalized,
            }
            if "matcher" in block:
                trusted_input["matcher"] = block["matcher"]
            trusted_hash = hashlib.sha256(
                json.dumps(
                    trusted_input,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode()
            ).hexdigest()
            state[f"{target}:{event_name}:{index}:0"] = {
                "enabled": True,
                "trusted_hash": f"sha256:{trusted_hash}",
            }
    if state:
        hooks["state"] = state


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: merge-codex-config TARGET FRAGMENT")

    target, fragment_path = map(Path, sys.argv[1:])
    target_text = _read(target)
    fragment_text = _read(fragment_path)
    markers = (f"# {GENERATED_COMMENT}", f"# {CONTAINER_COMMENT}")
    if not fragment_text.strip() and not any(
        marker in target_text for marker in markers
    ):
        return

    document = (
        tomlkit.parse(target_text) if target_text.strip() else tomlkit.document()
    )
    fragment = tomlkit.parse(fragment_text)
    _resolve_secrets(fragment)
    _add_hook_state(fragment, target)
    for key in fragment:
        _mark_generated(_item(fragment, key))

    _remove_generated(document)
    _merge_generated(document, fragment)

    # Re-adding generated entries after removal leaves blank lines that would
    # otherwise grow on every activation.
    output = re.sub(r"\n{3,}", "\n\n", tomlkit.dumps(document))
    if output != target_text:
        _write_atomic(target, output)


if __name__ == "__main__":
    main()
