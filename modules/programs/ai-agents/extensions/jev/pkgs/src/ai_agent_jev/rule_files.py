import json
import os
import re
import stat
import subprocess
import tempfile
from pathlib import Path


def project_root(cwd: Path, fallback: Path | None = None) -> Path:
    cwd = cwd.resolve()
    for directory in cwd, *cwd.parents:
        if (directory / ".git").exists():
            return directory
    if fallback is not None and cwd.is_relative_to(fallback.resolve()):
        return fallback.resolve()
    return cwd


def rules_directory(root: Path, handle: str | None = None) -> Path:
    parts = (
        [".agents", "rules"] if handle is None else [".agents", "session-rules", handle]
    )
    directory = root
    if handle is None and (root / ".git").exists():
        try:
            result = subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "rev-parse",
                    "--path-format=absolute",
                    "--git-common-dir",
                ],
                env={
                    name: value
                    for name, value in os.environ.items()
                    if name not in {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"}
                },
                capture_output=True,
                text=True,
                check=True,
                timeout=5,
            )
        except (OSError, subprocess.SubprocessError, UnicodeError) as error:
            raise OSError(
                f"Cannot resolve the Git common directory for {root}."
            ) from error
        common = result.stdout.rstrip("\n")
        if not common or not Path(common).is_absolute():
            raise OSError(f"Git returned an invalid common directory for {root}.")
        directory = Path(common).resolve()
        parts = ["ai-agent", "jev", "rules"]

    for part in parts:
        directory = directory / part
        if directory.is_symlink():
            raise ValueError(
                f"Rule directories must not be symbolic links: {directory}"
            )
    return directory


def rule_path(directory: Path, name: str) -> Path:
    if re.fullmatch(r"[A-Za-z0-9_-]+", name) is None:
        raise ValueError(
            "Rule IDs may contain only letters, digits, underscores, and hyphens."
        )
    path = directory / f"{name}.json"
    if path.is_symlink():
        raise ValueError(f"Rule files must not be symbolic links: {path}")
    return path


def read_json(path: Path) -> object:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, encoding="utf-8") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError(f"Expected a regular JSON file: {path}")
        try:
            return json.load(source)
        except (ValueError, UnicodeError) as error:
            raise ValueError(f"Invalid JSON file: {path}") from error


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    mode = 0o600
    if path.is_symlink():
        raise ValueError(f"JSON files must not be symbolic links: {path}")
    if path.exists():
        mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), mode)
            json.dump(value, output, ensure_ascii=False, indent=2, allow_nan=False)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def read_rules(directory: Path) -> dict[str, object]:
    try:
        paths = sorted(directory.iterdir())
    except FileNotFoundError:
        return {}
    return {
        path.stem: read_json(rule_path(directory, path.stem))
        for path in paths
        if path.suffix == ".json"
    }
