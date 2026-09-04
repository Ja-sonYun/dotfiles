import os
import subprocess
import sys

from hook_input import HookInput, is_proposed_plan, load_hook_input

STATUS_TIMEOUT_SECONDS = 1.0


def is_codex_input_tool(hook_input: HookInput, client: str) -> bool:
    tool_name = str(hook_input.get("tool_name") or "")
    return client == "Codex" and (
        tool_name in {"request_user_input", "_open_codex_api_key_setup"}
        or tool_name.startswith("confirm_")
    )


def state_for_event(hook_input: HookInput, client: str) -> str | None:
    event_name = str(hook_input.get("hook_event_name") or "")
    if event_name == "SessionStart":
        source = str(hook_input.get("source") or "")
        return "running" if client != "Codex" and source == "resume" else "idle"
    if event_name in {"PostToolUse", "UserPromptSubmit"}:
        return "running"
    if event_name == "PreToolUse":
        return None if is_codex_input_tool(hook_input, client) else "running"
    if event_name == "Notification":
        return "waiting"
    if event_name == "Stop":
        return "waiting" if is_proposed_plan(hook_input) else "idle"
    if event_name == "SessionEnd":
        return "idle"
    return None


def run_status(command: str, state: str) -> None:
    try:
        subprocess.run(
            [command, state],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=STATUS_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        pass


def main() -> int:
    client = os.environ.get("AI_AGENT_CLIENT")
    if len(sys.argv) != 2 or not client:
        return 2

    hook_input = load_hook_input(sys.stdin.read())
    state = state_for_event(hook_input, client)
    if state is not None:
        run_status(sys.argv[1], state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
