import json
import os
import sys
from collections.abc import MutableMapping, MutableSequence
from pathlib import Path
from typing import Any

import tomlkit
from tomlkit.items import AoT, Table


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


def _mark_generated_sections(value: Any) -> None:
    if isinstance(value, Table):
        value.comment("nix-generated")
        for child in value.values():
            _mark_generated_sections(child)
    elif isinstance(value, AoT):
        for table in value:
            _mark_generated_sections(table)


def _read_state(path: Path) -> list[str]:
    state = json.loads(_read(path) or "[]")
    if not isinstance(state, list) or not all(isinstance(name, str) for name in state):
        raise ValueError(f"invalid state file: {path}")
    return state


def _merge_named_table(
    document: Any,
    fragment: Any,
    key: str,
    previous_names: list[str],
) -> list[str]:
    new_items = fragment.get(key, {})
    current_items = document.get(key)
    if current_items is None:
        current_items = tomlkit.table()
        document[key] = current_items
    if not isinstance(current_items, MutableMapping) or not isinstance(
        new_items, MutableMapping
    ):
        raise ValueError(f"{key} must be a table")

    for name in previous_names:
        current_items.pop(name, None)
    for name, value in new_items.items():
        current_items[name] = value
    return list(new_items)


def _replace_key(document: Any, fragment: Any, key: str) -> None:
    document.pop(key, None)
    if key in fragment:
        document[key] = fragment[key]


def _merge_permission(document: Any, fragment: Any) -> None:
    permissions = document.get("permissions")
    managed = fragment.get("permissions", {}).get("managed")
    if permissions is None:
        permissions = tomlkit.table()
        document["permissions"] = permissions
    if not isinstance(permissions, MutableMapping):
        raise ValueError("permissions must be a table")

    permissions.pop("managed", None)
    if managed is not None:
        permissions["managed"] = managed


def _main() -> None:
    target, fragment_path, mcp_state_path, provider_state_path = map(
        Path, sys.argv[1:]
    )
    target_text = _read(target)
    document = (
        tomlkit.parse(target_text) if target_text.strip() else tomlkit.document()
    )
    fragment = tomlkit.parse(_read(fragment_path))
    _resolve_secrets(fragment)
    for value in fragment.values():
        _mark_generated_sections(value)
    if "default_permissions" in fragment:
        fragment["default_permissions"].comment("nix-generated")

    mcp_names = _merge_named_table(
        document,
        fragment,
        "mcp_servers",
        _read_state(mcp_state_path),
    )
    provider_names = _merge_named_table(
        document,
        fragment,
        "model_providers",
        _read_state(provider_state_path),
    )
    _replace_key(document, fragment, "features")
    _replace_key(document, fragment, "hooks")
    _replace_key(document, fragment, "tui")
    _replace_key(document, fragment, "default_permissions")
    _merge_permission(document, fragment)

    _write_atomic(target, tomlkit.dumps(document))
    _write_atomic(mcp_state_path, json.dumps(mcp_names))
    _write_atomic(provider_state_path, json.dumps(provider_names))


if __name__ == "__main__":
    _main()
