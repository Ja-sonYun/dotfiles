import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from types import FrameType

import tomllib
from ai_agent_hooks.edit_input import EditTarget, edit_targets
from ai_agent_hooks.hook_input import emit_feedback, load_hook_input

Command = tuple[Path, tuple[str, ...]]


class CommandError(RuntimeError):
    pass


def directories(directory: Path) -> list[Path]:
    result = []
    for parent in (directory, *directory.parents):
        result.append(parent)
        if (parent / ".git").exists():
            break
    return result


def find_config(directory: Path, *patterns: str) -> Path | None:
    for parent in directories(directory):
        for pattern in patterns:
            for candidate in sorted(parent.glob(pattern)):
                if candidate.is_file():
                    return candidate
    return None


def read_toml(path: Path) -> dict[str, object]:
    with path.open("rb") as source:
        return tomllib.load(source)


def command_plan(path: Path) -> tuple[list[Command], list[Command], list[str]]:
    formats: list[Command] = []
    checks: list[Command] = []
    notes: list[str] = []
    directory = path.parent
    filename = str(path)
    suffix = path.suffix.lower()
    if not suffix:
        with path.open("rb") as source:
            first_line = source.readline(256).decode("utf-8", errors="replace")
        if first_line.startswith("#!"):
            interpreters = {Path(word).name for word in first_line[2:].split()}
            if interpreters & {"sh", "bash", "ksh", "dash"}:
                suffix = ".sh"

    if suffix in {".py", ".pyi"}:
        formats.append((directory, ("ruff", "format", filename)))
        checks.append((directory, ("ruff", "check", filename)))
    elif suffix in {
        ".js",
        ".jsx",
        ".mjs",
        ".cjs",
        ".ts",
        ".tsx",
        ".mts",
        ".cts",
        ".md",
        ".markdown",
        ".mdx",
        ".json",
        ".jsonc",
        ".yaml",
        ".yml",
        ".html",
        ".htm",
        ".css",
        ".scss",
        ".less",
        ".vue",
        ".graphql",
        ".gql",
    }:
        prettier_args = ["prettier", "--write"]
        for name in (".prettierignore", ".gitignore"):
            ignore = find_config(directory, name)
            if ignore is not None:
                prettier_args.extend(("--ignore-path", str(ignore)))
        formats.append((directory, (*prettier_args, filename)))
        if suffix not in {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"}:
            return formats, checks, notes

        config = find_config(directory, "eslint.config.*", ".eslintrc", ".eslintrc.*")
        package_config = find_config(directory, "package.json")
        if config is None and package_config is not None:
            data = json.loads(package_config.read_text())
            if isinstance(data, dict) and "eslintConfig" in data:
                config = package_config
        if config is not None:
            checks.append((config.parent, ("eslint", filename)))
        else:
            notes.append(f"[skipped] {path}: no ESLint configuration")
    elif suffix in {".sh", ".bash", ".ksh"}:
        formats.append((directory, ("shfmt", "-w", filename)))
        checks.append((directory, ("shellcheck", filename)))
    elif suffix == ".nix":
        formats.append((directory, ("nixfmt", filename)))
        checks.append((directory, ("statix", "check", filename)))
    elif suffix in {".tf", ".tfvars"}:
        formats.append((directory, ("terraform", "fmt", filename)))
    elif suffix == ".go":
        formats.append((directory, ("gofmt", "-w", filename)))
    elif suffix in {".c", ".h", ".cc", ".hh", ".cpp", ".hpp", ".cxx", ".hxx"}:
        formats.append((directory, ("clang-format", "-i", "--style=file", filename)))
    elif suffix == ".java":
        formats.append((directory, ("google-java-format", "--replace", filename)))
    elif suffix in {".kt", ".kts"}:
        formats.append((directory, ("ktfmt", "--enable-editorconfig", filename)))
    elif suffix == ".rb":
        formats.append((directory, ("rubyfmt", "-i", filename)))
    elif suffix == ".toml":
        config = find_config(directory, ".taplo.toml", "taplo.toml")
        formats.append(
            (
                config.parent if config is not None else directory,
                ("taplo", "fmt", filename),
            )
        )
    elif suffix == ".lua":
        formats.append(
            (
                directory,
                (
                    "stylua",
                    "--respect-ignores",
                    "--search-parent-directories",
                    filename,
                ),
            )
        )
    elif suffix == ".sql":
        formats.append((directory, ("sqlfluff", "format", filename)))
    elif suffix == ".rs":
        config = find_config(directory, "Cargo.toml")
        rustfmt_args = ["rustfmt", "--config", "skip_children=true"]
        if config is not None:
            package = read_toml(config).get("package", {})
            edition = package.get("edition") if isinstance(package, dict) else None
            if isinstance(edition, dict) and edition.get("workspace"):
                for parent in directories(config.parent):
                    manifest = parent / "Cargo.toml"
                    if manifest.is_file():
                        workspace = read_toml(manifest).get("workspace", {})
                        if isinstance(workspace, dict):
                            workspace_package = workspace.get("package", {})
                            if (
                                isinstance(workspace_package, dict)
                                and "edition" in workspace_package
                            ):
                                edition = workspace_package["edition"]
                                break
            if isinstance(edition, str):
                rustfmt_args.extend(("--edition", edition))
        formats.append((directory, (*rustfmt_args, filename)))

    return formats, checks, notes


def executable(name: str, directory: Path) -> str | None:
    local_directories: tuple[str, ...] = ()
    if name == "ruff":
        local_directories = (".venv/bin",)
    elif name in {"prettier", "eslint"}:
        local_directories = ("node_modules/.bin",)
    if local_directories:
        for parent in directories(directory):
            for local_directory in local_directories:
                candidate = parent / local_directory / name
                if candidate.is_file() and os.access(candidate, os.X_OK):
                    return str(candidate)
    return shutil.which(name)


def terminate_process(process: subprocess.Popen[str], signum: int) -> None:
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass
    try:
        process.communicate(timeout=1)
    except subprocess.TimeoutExpired:
        pass
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.communicate()


def run_command(
    command: Command,
    tool_directory: Path,
    deadline: float,
) -> str:
    directory, args = command
    program = executable(args[0], tool_directory)
    label = f"{directory}: {shlex.join(args)}"
    if program is None:
        raise CommandError(f"[skipped] {label}: executable not available")
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise CommandError(f"[skipped] {label}: hook time limit reached")

    environment = os.environ.copy()
    if args[0] == "rustfmt":
        environment["RUSTUP_AUTO_INSTALL"] = "0"

    process: subprocess.Popen[str] | None = None
    completed = False
    termination_signal: int = signal.SIGTERM

    def interrupt(signum: int, _frame: FrameType | None) -> None:
        nonlocal termination_signal
        termination_signal = signum
        raise SystemExit(128 + signum)

    previous_handlers = {
        signum: signal.signal(signum, interrupt)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    try:
        process = subprocess.Popen(
            [program, *args[1:]],
            cwd=directory,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            start_new_session=True,
        )
        output, _ = process.communicate(timeout=remaining)
        completed = True
        if process.returncode:
            details = f"\n{output[-4000:]}"
            raise CommandError(
                f"[failed: {process.returncode}] {label}{details}",
            )
        return output
    except subprocess.TimeoutExpired as error:
        raise CommandError(f"[timeout] {label}") from error
    except OSError as error:
        raise CommandError(f"[skipped] {label}: {error}") from error
    finally:
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if process is not None:
                if not completed:
                    terminate_process(process, termination_signal)
                if process.stdout is not None:
                    process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)


def post_edit_checks(targets: list[EditTarget], deadline: float) -> list[str]:
    formats: list[Command] = []
    checks: list[Command] = []
    notes: list[str] = []
    tool_directories: dict[Command, Path] = {}
    for path in dict.fromkeys(
        target.after for target in targets if target.after.is_file()
    ):
        try:
            file_formats, file_checks, file_notes = command_plan(path)
        except (OSError, ValueError) as error:
            notes.append(
                f"[skipped] {path}: cannot read project configuration: {error}"
            )
            continue
        formats.extend(file_formats)
        checks.extend(file_checks)
        notes.extend(file_notes)
        for command in (*file_formats, *file_checks):
            tool_directories.setdefault(command, path.parent)

    for command in dict.fromkeys([*formats, *checks]):
        try:
            run_command(command, tool_directories[command], deadline)
        except CommandError as error:
            notes.append(str(error))

    return notes


def main() -> int:
    hook_input = load_hook_input(sys.stdin.read())
    if hook_input.get("hook_event_name") != "PostToolUse":
        return 0
    notes = post_edit_checks(edit_targets(hook_input), time.monotonic() + 120)
    if notes:
        notes.insert(
            0,
            "Post-edit format and lint checks. If the user explicitly asks to ignore these results, continue without requiring fixes.",
        )
    emit_feedback("PostToolUse", notes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
