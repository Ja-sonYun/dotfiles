import json

from ai_agent_hooks.hook_input import HOOK_OUTPUT_BYTES

from ai_agent_rules.context import write_output


def emit_feedback(
    event: str, notes: list[str], *, deny_reason: str | None = None
) -> None:
    """Emit bounded feedback, applying an optional denial only to PreToolUse."""
    if not notes and deny_reason is None:
        return
    feedback = "\n\n".join(dict.fromkeys(notes))
    # Leave room for adapters to restore the PostToolUseFailure event name.
    output_limit = HOOK_OUTPUT_BYTES - (len("Failure") if event == "PostToolUse" else 0)

    def serialize(text: str) -> str:
        specific = {
            "hookEventName": event,
            "additionalContext": text,
        }
        if event == "PreToolUse" and deny_reason is not None:
            specific.update(
                permissionDecision="deny", permissionDecisionReason=deny_reason
            )
        return (
            json.dumps(
                {"hookSpecificOutput": specific},
                ensure_ascii=False,
            )
            + "\n"
        )

    output = serialize(feedback)
    if len(output.encode("utf-8")) > output_limit:
        suffix = "\n\n[truncated] Additional hook feedback did not fit."
        low, high = 0, len(feedback)
        while low < high:
            middle = (low + high + 1) // 2
            if (
                len(serialize(feedback[:middle] + suffix).encode("utf-8"))
                <= output_limit
            ):
                low = middle
            else:
                high = middle - 1
        output = serialize(feedback[:low] + suffix)
    write_output(output)
