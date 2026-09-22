import json

HookInput = dict[str, object]
HOOK_OUTPUT_BYTES = 64 * 1024


def load_hook_input(raw_input: str) -> HookInput:
    try:
        value = json.loads(raw_input or "{}")
    except json.JSONDecodeError:
        return {}
    if not isinstance(value, dict):
        return {}
    return {str(key): item for key, item in value.items()}


def is_proposed_plan(hook_input: HookInput) -> bool:
    message = str(hook_input.get("last_assistant_message") or "")
    return "<proposed_plan>" in message.lower()


def emit_feedback(event: str, notes: list[str]) -> None:
    if not notes:
        return
    feedback = "\n\n".join(dict.fromkeys(notes))
    # Leave room for adapters to restore the PostToolUseFailure event name.
    output_limit = HOOK_OUTPUT_BYTES - (len("Failure") if event == "PostToolUse" else 0)

    def serialize(text: str) -> str:
        return (
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "additionalContext": text,
                    }
                },
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
    print(output, end="")
