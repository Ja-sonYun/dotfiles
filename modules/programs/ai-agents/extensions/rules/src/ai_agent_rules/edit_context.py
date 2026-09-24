from ai_agent_hooks.edit_input import edit_targets
from ai_agent_hooks.hook_input import HookInput

from ai_agent_rules.code_changes import (
    MAX_SOURCE_BYTES,
    replacement_context,
    source_text,
)


def capture_context(hook_input: HookInput) -> list[str] | None:
    """Compute replacement lines before execution without changing the source."""
    tool = str(hook_input.get("tool_name") or "").rsplit(".", 1)[-1].lower()
    if tool not in {"edit", "multiedit", "edit_file"}:
        return None
    targets = edit_targets(hook_input)
    if len(targets) != 1:
        raise ValueError("replacement context requires one file")
    _, texts = replacement_context(
        source_text(targets[0].before), hook_input.get("tool_input")
    )
    if sum(len(text.encode("utf-8")) for text in texts) > MAX_SOURCE_BYTES:
        raise ValueError("replacement context exceeds the 1 MiB inspection limit")
    return texts
