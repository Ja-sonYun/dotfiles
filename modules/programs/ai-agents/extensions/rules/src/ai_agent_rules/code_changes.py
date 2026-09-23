import json
import re
from dataclasses import dataclass
from pathlib import Path

from ai_agent_hooks.edit_input import edit_targets
from ai_agent_hooks.hook_input import HookInput

MAX_SOURCE_BYTES = 1024 * 1024


@dataclass(frozen=True)
class Inspection:
    path: Path
    kind: str
    code: str
    regex_text: str | None = None

    def matching_text(self) -> str:
        """Return added text, preserving physical lines for replacements."""
        if self.kind == "patch":
            return added_text(self.code)
        if self.kind == "replacement":
            if self.regex_text is None:
                raise ValueError("replacement line context is unavailable")
            return self.regex_text
        if self.kind == "notebook_cell":
            return str(json.loads(self.code)["new_source"])
        return self.code


def added_text(patch: str) -> str:
    """Extract added lines from an apply_patch or unified patch."""
    lines = []
    in_hunk = False
    for line in patch.splitlines():
        if line.startswith(("*** Add File:", "*** Update File:")):
            in_hunk = True
        elif line.startswith("*** Move to:"):
            continue
        elif line.startswith(("*** ", "diff --git ")):
            in_hunk = False
        elif line.startswith("@@"):
            in_hunk = True
        elif in_hunk and line.startswith("+"):
            lines.append(line[1:])
    return "\n".join(lines)


def check_source_path(path: Path) -> None:
    if (
        re.search(r"(^|\.)env($|\.)", path.name, re.IGNORECASE)
        or path.suffix.lower() in {".age", ".pem", ".key", ".p12", ".pfx", ".gpg"}
        or ".ssh" in path.parts
        or (path.name == "credentials" and path.parent.name == ".aws")
    ):
        raise ValueError("sensitive file excluded")


def source_text(path: Path) -> str:
    check_source_path(path)
    with path.open("rb") as source:
        data = source.read(MAX_SOURCE_BYTES + 1)
    if len(data) > MAX_SOURCE_BYTES:
        raise ValueError("source exceeds the 1 MiB inspection limit")
    if b"\0" in data:
        raise ValueError("binary file excluded")
    return data.decode("utf-8")


def replacement_edits(tool_input: object) -> list[tuple[str, str, bool]]:
    if not isinstance(tool_input, dict):
        raise TypeError("missing edit input")
    edits = tool_input.get("edits", [tool_input])
    if not isinstance(edits, list):
        raise TypeError("invalid replacement input")
    result = []
    for edit in edits:
        if not isinstance(edit, dict):
            raise TypeError("invalid replacement input")
        old = edit.get("old_string", edit.get("oldText"))
        new = edit.get("new_string", edit.get("newText"))
        if not isinstance(old, str) or not isinstance(new, str):
            raise TypeError("missing replacement text")
        if "\0" in old or "\0" in new:
            raise ValueError("binary replacement excluded")
        result.append((old, new, edit.get("replace_all") is True))
    return result


def replacement_context(source: str, tool_input: object) -> tuple[str, list[str]]:
    edits = replacement_edits(tool_input)
    spans: list[tuple[int, int, int]] = []
    for index, (old, new, replace_all) in enumerate(edits):
        count = source.count(old)
        if not old or not count:
            raise ValueError("cannot locate the original replacement text")
        if not replace_all and count != 1:
            raise ValueError("replacement location is ambiguous")
        positions = [match.start() for match in re.finditer(re.escape(old), source)]
        for start in reversed(positions):
            end = start + len(old)
            shift = len(new) - len(old)
            remaining = []
            # Preserve only earlier replacement text that this edit does not overwrite.
            for owner, left, right in spans:
                if left < start:
                    remaining.append((owner, left, min(right, start)))
                if right > end:
                    remaining.append((owner, max(left, end) + shift, right + shift))
            if new:
                remaining.append((index, start, start + len(new)))
            spans = remaining
            source = source[:start] + new + source[end:]
        if len(source.encode("utf-8")) > MAX_SOURCE_BYTES:
            raise ValueError("replacement result exceeds the 1 MiB inspection limit")

    texts = []
    for index, (_, new, _) in enumerate(edits):
        if not new:
            continue
        ranges = sorted(
            {
                (
                    left if source[left] in "\r\n" else source.rfind("\n", 0, left) + 1,
                    source.find("\n", right - 1),
                )
                for owner, left, right in spans
                if owner == index
            }
        )
        merged: list[tuple[int, int]] = []
        for left, right in ranges:
            if right < 0:
                right = len(source)
            if merged and left <= merged[-1][1] + 1:
                merged[-1] = (merged[-1][0], max(merged[-1][1], right))
            else:
                merged.append((left, right))
        texts.append("\n".join(source[left:right] for left, right in merged))
    return source, texts


def inspections(
    hook_input: HookInput, matching_texts: list[str] | None = None
) -> tuple[list[Inspection], list[str]]:
    targets = edit_targets(hook_input)
    if not targets:
        return [], []
    tool_name = str(hook_input.get("tool_name") or "").rsplit(".", 1)[-1].lower()
    tool_input = hook_input.get("tool_input")
    inputs: list[Inspection] = []
    notes: list[str] = []
    try:
        if tool_name == "apply_patch":
            patch = tool_input
            if isinstance(tool_input, dict):
                patch = (
                    tool_input.get("patch")
                    or tool_input.get("command")
                    or tool_input.get("input")
                )
            if not isinstance(patch, str):
                raise TypeError("missing patch input")
            for block in re.split(
                r"(?=^\*\*\* (?:Add|Update|Delete) File: )", patch, flags=re.MULTILINE
            ):
                if block.startswith("*** Delete File:") or not any(
                    line.startswith("+") for line in block.splitlines()
                ):
                    continue
                block_targets = edit_targets({**hook_input, "tool_input": block})
                if block_targets:
                    try:
                        check_source_path(block_targets[0].before)
                        check_source_path(block_targets[0].after)
                    except ValueError as error:
                        notes.append(
                            f"[Rules not checked] {block_targets[0].after}: {error}"
                        )
                        continue
                    inputs.append(Inspection(block_targets[0].after, "patch", block))
        elif isinstance(tool_input, dict):
            for target in targets:
                check_source_path(target.before)
                check_source_path(target.after)
            if tool_name == "notebookedit":
                if tool_input.get("edit_mode") != "delete":
                    content = tool_input.get("new_source")
                    if not isinstance(content, str):
                        raise TypeError("missing notebook cell source")
                    inputs.append(
                        Inspection(
                            targets[0].after,
                            "notebook_cell",
                            json.dumps(
                                {
                                    "cell_id": tool_input.get("cell_id"),
                                    "cell_type": tool_input.get("cell_type"),
                                    "new_source": content,
                                },
                                ensure_ascii=False,
                            ),
                        )
                    )
            elif tool_name in {"write", "write_file"}:
                content = tool_input.get("content")
                if not isinstance(content, str):
                    raise TypeError("missing write content")
                inputs.append(Inspection(targets[0].after, "write", content))
            else:
                for old, new, _ in replacement_edits(tool_input):
                    if new:
                        inputs.append(
                            Inspection(
                                targets[0].after,
                                "replacement",
                                json.dumps(
                                    {"old_text": old, "replacement": new},
                                    ensure_ascii=False,
                                ),
                                matching_texts[len(inputs)]
                                if matching_texts is not None
                                else None,
                            )
                        )
        else:
            raise ValueError("missing edit input")
    except (TypeError, ValueError) as error:
        return [], [f"[Rules not checked] Editing tool input: {error}"]

    eligible = []
    for inspection in inputs:
        if (
            "\0" in inspection.code
            or len(inspection.code.encode("utf-8")) > MAX_SOURCE_BYTES
        ):
            notes.append(
                f"[Rules not checked] {inspection.path}: binary or oversized input"
            )
        else:
            eligible.append(inspection)
    return eligible, notes


def project_instructions(path: Path) -> str:
    directories = []
    for directory in path.parent, *path.parent.parents:
        directories.append(directory)
        if (directory / ".git").exists():
            break
    else:
        directories = [path.parent]

    instructions = []
    for directory in reversed(directories):
        source = directory / "AGENTS.md"
        if source.is_file():
            instructions.append(f"{source}:\n{source_text(source)}")
    return "\n\n".join(instructions)
