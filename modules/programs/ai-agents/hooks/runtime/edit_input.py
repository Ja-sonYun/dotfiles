from dataclasses import dataclass
from pathlib import Path

from ai_agent_hooks.hook_input import HookInput


@dataclass(frozen=True)
class EditTarget:
    before: Path
    after: Path


def edit_targets(
    hook_input: HookInput, *, resolve_paths: bool = True
) -> list[EditTarget]:
    tool_name = str(hook_input.get("tool_name") or "").rsplit(".", 1)[-1].lower()
    tool_input = hook_input.get("tool_input")
    response = hook_input.get("tool_response")
    if hook_input.get("tool_failed") is True or (
        isinstance(response, dict) and response.get("isError")
    ):
        return []

    paths: list[tuple[str, str]] = []
    if tool_name in {
        "write",
        "edit",
        "multiedit",
        "notebookedit",
        "write_file",
        "edit_file",
    }:
        if isinstance(tool_input, dict):
            path = (
                tool_input.get("notebook_path")
                if tool_name == "notebookedit"
                else tool_input.get("file_path") or tool_input.get("path")
            )
            if isinstance(path, str):
                paths.append((path, path))
    elif tool_name == "apply_patch":
        patch = tool_input
        if isinstance(tool_input, dict):
            patch = (
                tool_input.get("patch")
                or tool_input.get("command")
                or tool_input.get("input")
            )
        if isinstance(patch, str):
            for line in patch.splitlines():
                if line.startswith(
                    ("*** Add File: ", "*** Update File: ", "*** Delete File: ")
                ):
                    path = line.split(": ", 1)[1]
                    paths.append((path, path))
                elif line.startswith("*** Move to: ") and paths:
                    paths[-1] = (paths[-1][0], line.removeprefix("*** Move to: "))

    cwd = Path(str(hook_input.get("cwd") or Path.cwd()))

    def target_path(value: str) -> Path:
        path = cwd / Path(value).expanduser()
        return path.resolve() if resolve_paths else path.absolute()

    return list(
        dict.fromkeys(
            EditTarget(target_path(before), target_path(after))
            for before, after in paths
        )
    )
