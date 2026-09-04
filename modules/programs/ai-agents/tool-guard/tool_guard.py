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
    approval_token: str
    input_fields: tuple[str, ...]
    input_patterns: tuple[re.Pattern[str], ...]
    reason: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument(
        "--event",
        required=True,
        choices=("UserPromptSubmit", "PreToolUse", "SessionEnd"),
    )
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


def matches_approval_token(line: str, approval_token: str) -> bool:
    candidate = line.strip()
    return candidate == approval_token or candidate.strip("`\\") == approval_token


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
        approval_token = fields.get("approvalToken")
        input_fields = fields.get("inputFields", [])
        input_patterns = fields.get("inputPatterns", [])
        reason = fields.get("reason", "")
        if not isinstance(matcher, str) or not isinstance(approval_token, str):
            raise ValueError(f"Tool Guard {client}.{name} is invalid.")
        if (
            not isinstance(reason, str)
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
                approval_token=approval_token,
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


def state_path(client: str, session_id: str) -> Path:
    digest = hashlib.sha256(f"{client}\0{session_id}".encode()).hexdigest()
    return state_directory() / digest


def read_authorization(path: Path) -> tuple[str, set[str]] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(value, dict):
        return None

    prompt_id = value.get("promptId")
    approved = value.get("approvedGuards")
    if not isinstance(prompt_id, str) or not isinstance(approved, list):
        return None
    return prompt_id, {item for item in approved if isinstance(item, str)}


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


def emit_context(event: str, message: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": event,
                "additionalContext": message,
            }
        },
        sys.stdout,
    )


def update_authorization(
    hook_input: dict[str, object], client: str, guards: list[Guard]
) -> int:
    if not guards:
        return 0

    session_id = string_field(hook_input, "session_id")
    prompt_id = string_field(hook_input, "prompt_id")
    prompt = string_field(hook_input, "prompt")
    if session_id is None or prompt_id is None or prompt is None:
        emit_context(
            "UserPromptSubmit",
            "Tool Guard could not read this prompt; guarded tools remain blocked.",
        )
        return 0

    approved = {
        guard.name
        for guard in guards
        if any(
            matches_approval_token(line, guard.approval_token)
            for line in prompt.splitlines()
        )
    }
    path = state_path(client, session_id)
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {
                    "promptId": prompt_id,
                    "approvedGuards": sorted(approved),
                }
            ),
            encoding="utf-8",
        )
        if approved:
            emit_context(
                "UserPromptSubmit",
                "Tool Guard authorization applies only to this user turn.",
            )
    except OSError:
        emit_context(
            "UserPromptSubmit",
            "Tool Guard could not store authorization; guarded tools remain blocked.",
        )
    return 0


def check_authorization(
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
    prompt_id = string_field(hook_input, "prompt_id")
    if session_id is None or prompt_id is None:
        emit_denial("Tool Guard could not identify the current user turn.")
        return 0

    authorization = read_authorization(state_path(client, session_id))
    approved = (
        authorization[1]
        if authorization is not None and authorization[0] == prompt_id
        else set()
    )
    missing = [guard for guard in matching_guards if guard.name not in approved]
    if not missing:
        return 0

    tokens = ", ".join(guard.approval_token for guard in missing)
    reasons = "".join(
        f"{reason} "
        for reason in dict.fromkeys(guard.reason for guard in missing)
        if reason
    )
    emit_denial(
        f"{reasons}{tool_name} requires explicit user authorization. Do not retry in this "
        "turn. End the turn and ask the user to send a new message containing each "
        f"required approval token as its own line: {tokens}."
    )
    return 0


def clear_authorization(hook_input: dict[str, object], client: str) -> int:
    session_id = string_field(hook_input, "session_id")
    if session_id is not None:
        try:
            state_path(client, session_id).unlink(missing_ok=True)
        except OSError:
            pass
    return 0


def main() -> int:
    args = parse_args()
    event: str = args.event
    client = os.environ.get("AI_AGENT_CLIENT", "")
    if not client:
        if event == "PreToolUse":
            emit_denial("Tool Guard could not identify the active AI agent.")
        elif event == "UserPromptSubmit":
            emit_context(event, "Tool Guard could not identify the active AI agent.")
        return 0

    hook_input = read_hook_input()
    if hook_input is None:
        if event == "PreToolUse":
            emit_denial("Tool Guard could not validate authorization.")
        elif event == "UserPromptSubmit":
            emit_context(event, "Tool Guard received invalid hook input.")
        return 0

    try:
        guards = load_guards(args.config, client)
    except (json.JSONDecodeError, OSError, re.error, ValueError) as error:
        if event == "PreToolUse":
            emit_denial(f"Tool Guard configuration is invalid: {error}")
        elif event == "UserPromptSubmit":
            emit_context(event, f"Tool Guard configuration is invalid: {error}")
        return 0

    if event == "UserPromptSubmit":
        return update_authorization(hook_input, client, guards)
    if event == "PreToolUse":
        return check_authorization(hook_input, client, guards)
    return clear_authorization(hook_input, client)


if __name__ == "__main__":
    raise SystemExit(main())
