import json
import os
import subprocess
import sys
import time

from hook_input import HookInput, is_proposed_plan, load_hook_input

STATUS_TIMEOUT_SECONDS = 1.0
CODEX_SESSION_END_BUDGET_SECONDS = 0.8


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


def run_status(command: str, state: str, deadline: float | None = None) -> None:
    timeout = (
        STATUS_TIMEOUT_SECONDS if deadline is None else deadline - time.monotonic()
    )
    if timeout <= 0:
        return
    try:
        subprocess.run(
            [command, state],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        pass


def update_title(
    tmux: str, hook_input: HookInput, client: str, deadline: float | None = None
) -> None:
    pane = os.environ.get("TMUX_PANE")
    session_id = hook_input.get("session_id")
    event = hook_input.get("hook_event_name")
    if not pane or not isinstance(session_id, str) or not session_id:
        return
    if event not in {"SessionStart", "SessionEnd", "UserPromptSubmit", "StatusLine"}:
        return
    if event == "UserPromptSubmit" and client != "Codex":
        return

    option = "@agent_conversation"
    timeout = (
        STATUS_TIMEOUT_SECONDS if deadline is None else deadline - time.monotonic()
    )
    if timeout <= 0:
        return
    try:
        output = subprocess.run(
            [tmux, "show-options", "-p", "-q", "-v", "-t", pane, option],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
        ).stdout
        try:
            current = json.loads(output or "{}")
        except json.JSONDecodeError:
            current = {}
        if not isinstance(current, dict):
            current = {}
        same_session = (
            current.get("session_id") == session_id and current.get("client") == client
        )
        if event == "SessionEnd":
            if not same_session:
                return
            arguments = ["set-option", "-p", "-u", "-t", pane, option]
        else:
            if event == "UserPromptSubmit" and current and not same_session:
                return
            field = "session_name" if event == "StatusLine" else "session_title"
            title = hook_input.get(field)
            title_known = isinstance(title, str) or event == "StatusLine"
            if not isinstance(title, str):
                title = ""
                if (
                    not title_known
                    and same_session
                    and current.get("title_known") is True
                    and isinstance(current.get("title"), str)
                ):
                    title = current["title"]
                    title_known = True
            value = {
                "client": client,
                "session_id": session_id,
                "title": title,
                "title_known": title_known,
            }
            if value == current:
                return
            arguments = ["set-option", "-p", "-t", pane, option, json.dumps(value)]
        timeout = (
            STATUS_TIMEOUT_SECONDS if deadline is None else deadline - time.monotonic()
        )
        if timeout <= 0:
            return
        subprocess.run(
            [tmux, *arguments],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def main() -> int:
    started = time.monotonic()
    client = os.environ.get("AI_AGENT_CLIENT")
    if len(sys.argv) != 3 or not client:
        return 2

    hook_input = load_hook_input(sys.stdin.read())
    if sys.argv[1] == "--statusline":
        hook_input["hook_event_name"] = "StatusLine"
    if client == "Codex" and hook_input.get("hook_event_name") == "SessionEnd":
        deadline = started + CODEX_SESSION_END_BUDGET_SECONDS
        run_status(sys.argv[1], "idle", deadline)
        update_title(sys.argv[2], hook_input, client, deadline)
        return 0
    update_title(sys.argv[2], hook_input, client)
    if sys.argv[1] == "--statusline":
        return 0
    state = state_for_event(hook_input, client)
    if state is not None:
        run_status(sys.argv[1], state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
