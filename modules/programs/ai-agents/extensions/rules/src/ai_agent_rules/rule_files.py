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


def rules_directory(root: Path) -> Path:
    directory = root
    if (root / ".git").exists():
        environment = {
            name: value
            for name, value in os.environ.items()
            if name not in {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"}
        }
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
                env=environment,
                capture_output=True,
                text=True,
                check=True,
                timeout=5,
            )
            common = result.stdout.rstrip("\n")
            if not common or not Path(common).is_absolute():
                raise OSError("Git returned an invalid common directory.")
            common_directory = Path(common).resolve()

            # Submodules may list their Git metadata directory as the main worktree.
            result = subprocess.run(
                [
                    "git",
                    "config",
                    "--file",
                    str(common_directory / "config"),
                    "--null",
                    "--get",
                    "core.worktree",
                ],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
            if result.returncode == 1:
                result = subprocess.run(
                    ["git", "-C", str(root), "worktree", "list", "--porcelain", "-z"],
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=5,
                )
                first = result.stdout.split("\0", 1)[0]
                if not first.startswith("worktree "):
                    raise OSError("Git returned an invalid worktree list.")
                directory = Path(first.removeprefix("worktree "))
                if not directory.is_absolute():
                    raise OSError("Git returned an invalid main worktree path.")
                directory = directory.resolve()
            else:
                result.check_returncode()
                checkout = result.stdout.removesuffix("\0")
                if not checkout:
                    raise OSError("Git returned an empty core.worktree path.")
                directory = (common_directory / checkout).resolve()
        except (OSError, subprocess.SubprocessError, UnicodeError) as error:
            raise OSError(f"Cannot resolve the main checkout for {root}.") from error

    for part in (".agents", "rules"):
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
        if path.suffix == ".json" and re.fullmatch(r"[A-Za-z0-9_-]+", path.stem)
    }
