import json

HookInput = dict[str, object]


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
