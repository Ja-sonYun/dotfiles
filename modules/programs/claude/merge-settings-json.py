import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import TypedDict

type JSON = None | bool | int | float | str | list[JSON] | dict[str, JSON]


class Ownership(TypedDict):
    leaves: list[list[str]]
    containers: list[list[str]]


def _read_object(path: Path) -> dict[str, JSON]:
    value: JSON = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"{path}: expected a JSON object")
    return value


def _read_paths(value: JSON) -> list[list[str]]:
    if not isinstance(value, list):
        raise TypeError("managed paths must be an array")

    paths: list[list[str]] = []
    for path in value:
        if not isinstance(path, list) or not path:
            raise ValueError("each managed path must be a nonempty array")
        components: list[str] = []
        for component in path:
            if not isinstance(component, str):
                raise TypeError("managed path components must be strings")
            components.append(component)
        paths.append(components)
    return paths


def _remove_path(
    document: dict[str, JSON],
    path: list[str],
    *,
    empty_only: bool = False,
) -> None:
    parent = document
    for key in path[:-1]:
        child = parent.get(key)
        if not isinstance(child, dict):
            return
        parent = child
    if not empty_only or parent.get(path[-1]) == {}:
        parent.pop(path[-1], None)


def _merge(
    document: dict[str, JSON],
    fragment: dict[str, JSON],
    ownership: Ownership,
    path: list[str],
) -> None:
    for key, value in fragment.items():
        current_path = [*path, key]
        if isinstance(value, dict):
            current = document.get(key)
            if not isinstance(current, dict):
                current = {}
                document[key] = current
                ownership["containers"].append(current_path)
            _merge(current, value, ownership, current_path)
        else:
            # Own arrays as a whole so removed hooks do not survive a deployment.
            document[key] = value
            ownership["leaves"].append(current_path)


def _stage(path: Path, text: str) -> Path:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        mode = 0
    permissions = stat.S_IMODE(mode) if stat.S_ISREG(mode) else 0o600
    descriptor, name = tempfile.mkstemp(prefix=f"{path.name}.hm-tmp.", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            file.write(text)
        temporary.chmod(permissions)
    except OSError as exc:
        raise OSError(
            f"failed to stage {path}: {exc}; temporary file retained: {temporary}"
        ) from exc
    return temporary


def main() -> int:
    """Apply Nix settings while preserving keys outside their recorded ownership.

    Replace settings before ownership metadata. If the second replacement fails,
    keep the updated settings and staged metadata, report their paths, and fail.
    """
    if len(sys.argv) != 3:
        print("usage: merge-settings-json.py TARGET FRAGMENT", file=sys.stderr)
        return 2

    target, fragment_path = map(Path, sys.argv[1:])
    managed_path = target.with_name(f"{target.name}.nix-managed.json")
    staged: list[tuple[Path, Path]] = []
    stage = "read settings"
    try:
        try:
            document = _read_object(target)
        except FileNotFoundError:
            document = {}
        stage = "read Nix settings"
        fragment = _read_object(fragment_path)
        stage = "read managed paths"
        try:
            managed = _read_object(managed_path)
        except FileNotFoundError:
            managed = {"leaves": [], "containers": []}
        leaves = _read_paths(managed.get("leaves"))
        containers = _read_paths(managed.get("containers"))

        for path in leaves:
            _remove_path(document, path)
        for path in sorted(containers, key=len, reverse=True):
            _remove_path(document, path, empty_only=True)
        ownership: Ownership = {"leaves": [], "containers": []}
        _merge(document, fragment, ownership, [])

        stage = "serialize settings and managed paths"
        outputs = (
            (target, json.dumps(document, indent=2, allow_nan=False) + "\n"),
            (managed_path, json.dumps(ownership, indent=2) + "\n"),
        )
        for destination, text in outputs:
            stage = f"stage {destination}"
            staged.append((destination, _stage(destination, text)))
        for destination, temporary in staged:
            stage = f"replace {destination}"
            os.replace(temporary, destination)
    except (OSError, TypeError, ValueError) as exc:
        print(f"{target}: failed to {stage}: {exc}", file=sys.stderr)
        for _, temporary in staged:
            if temporary.exists():
                print(f"temporary file retained: {temporary}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
