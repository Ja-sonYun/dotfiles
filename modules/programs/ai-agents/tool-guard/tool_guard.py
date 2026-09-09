import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Guard:
    name: str
    matcher: re.Pattern[str]
    on_block: str
    input_fields: tuple[str, ...]
    input_patterns: tuple[re.Pattern[str], ...]
    reason: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    return parser.parse_args()


def read_hook_input() -> dict[str, object] | None:
    try:
        value = json.load(sys.stdin)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def string_field(hook_input: dict[str, object], name: str) -> str | None:
    value = hook_input.get(name)
    return value if isinstance(value, str) and value else None


def load_guards(config_path: Path, client: str) -> list[Guard]:
    value = json.loads(config_path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("Tool Guard configuration must be an object.")

    configured = value.get(client, {})
    if not isinstance(configured, dict):
        raise ValueError(f"Tool Guard configuration for {client} must be an object.")

    guards: list[Guard] = []
    for name, fields in configured.items():
        if not isinstance(name, str) or not isinstance(fields, dict):
            raise ValueError(f"Tool Guard configuration for {client} is invalid.")
        matcher = fields.get("matcher")
        on_block = fields.get("onBlock", "request-approval")
        input_fields = fields.get("inputFields", [])
        input_patterns = fields.get("inputPatterns", [])
        reason = fields.get("reason", "")
        if not isinstance(matcher, str):
            raise ValueError(f"Tool Guard {client}.{name} is invalid.")
        if (
            on_block not in ("request-approval", "revise-input")
            or not isinstance(reason, str)
            or not isinstance(input_fields, list)
            or not isinstance(input_patterns, list)
            or not all(isinstance(item, str) for item in input_fields)
            or not all(isinstance(item, str) for item in input_patterns)
        ):
            raise ValueError(f"Tool Guard {client}.{name} is invalid.")
        if bool(input_fields) != bool(input_patterns):
            raise ValueError(
                f"Tool Guard {client}.{name} needs both `inputFields` and `inputPatterns`."
            )
        guards.append(
            Guard(
                name=name,
                matcher=re.compile(matcher),
                on_block=on_block,
                input_fields=tuple(input_fields),
                input_patterns=tuple(re.compile(pattern) for pattern in input_patterns),
                reason=reason,
            )
        )
    return guards


def string_values(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str)]
    return []


def field_values(value: object, fields: tuple[str, ...]) -> list[str]:
    """Collect strings stored under `fields` anywhere inside a tool input."""
    if isinstance(value, dict):
        return [
            found
            for key, item in value.items()
            for found in (
                string_values(item) if key in fields else field_values(item, fields)
            )
        ]
    if isinstance(value, list):
        return [found for item in value for found in field_values(item, fields)]
    return []


def guard_applies(guard: Guard, tool_name: str, tool_input: object) -> bool:
    if not guard.matcher.search(tool_name):
        return False
    if not guard.input_patterns:
        return True
    return any(
        pattern.search(value)
        for value in field_values(tool_input, guard.input_fields)
        for pattern in guard.input_patterns
    )


def state_directory() -> Path:
    if runtime_directory := os.environ.get("XDG_RUNTIME_DIR"):
        return Path(runtime_directory) / "ai-agent-tool-guard"
    if state_home := os.environ.get("XDG_STATE_HOME"):
        return Path(state_home) / "ai-agents" / "tool-guard"
    return Path.home() / ".local" / "state" / "ai-agents" / "tool-guard"


def state_path(client: str, session_id: str, guard_name: str) -> Path:
    digest = hashlib.sha256(
        f"{client}\0{session_id}\0{guard_name}".encode()
    ).hexdigest()
    return state_directory() / digest


def mark_first_block(client: str, session_id: str, guard_name: str) -> bool:
    path = state_path(client, session_id, guard_name)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        path.touch(mode=0o600, exist_ok=False)
    except FileExistsError:
        return False
    return True


def emit_denial(reason: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


def check_first_use(
    hook_input: dict[str, object], client: str, guards: list[Guard]
) -> int:
    tool_name = string_field(hook_input, "tool_name")
    if tool_name is None:
        emit_denial("Tool Guard could not identify the requested tool.")
        return 0

    matching_guards = [
        guard
        for guard in guards
        if guard_applies(guard, tool_name, hook_input.get("tool_input"))
    ]
    if not matching_guards:
        return 0

    session_id = string_field(hook_input, "session_id")
    if session_id is None:
        emit_denial("Tool Guard could not identify the current conversation.")
        return 0

    try:
        first_guards = [
            guard
            for guard in matching_guards
            if mark_first_block(client, session_id, guard.name)
        ]
    except OSError as error:
        emit_denial(f"Tool Guard could not record the first block: {error}")
        return 0
    if not first_guards:
        return 0

    approval_required = [
        guard for guard in first_guards if guard.on_block == "request-approval"
    ]
    reasons = "".join(
        f"{reason} "
        for reason in dict.fromkeys(guard.reason for guard in first_guards)
        if reason
    )
    if approval_required:
        emit_denial(
            f"{reasons}{tool_name} was blocked before execution. "
            "If the intended use is not already authorized, you must explain it "
            "and ask the user for permission. You must not retry until approval "
            "is given. "
            "Stay within the approved scope."
        )
    else:
        emit_denial(
            f"{reasons}{tool_name} was blocked before execution. "
            "You must correct any actual violation before retrying. "
            "You must not change valid input merely to avoid the guard."
        )
    return 0


def main() -> int:
    args = parse_args()
    client = os.environ.get("AI_AGENT_CLIENT", "")
    if not client:
        emit_denial("Tool Guard could not identify the active AI agent.")
        return 0

    hook_input = read_hook_input()
    if hook_input is None:
        emit_denial("Tool Guard received invalid hook input.")
        return 0

    try:
        guards = load_guards(args.config, client)
    except (json.JSONDecodeError, OSError, re.error, ValueError) as error:
        emit_denial(f"Tool Guard configuration is invalid: {error}")
        return 0

    return check_first_use(hook_input, client, guards)


if __name__ == "__main__":
    raise SystemExit(main())
