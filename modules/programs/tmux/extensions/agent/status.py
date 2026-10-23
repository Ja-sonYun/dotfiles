import json
import os
import subprocess
import sys
import time

from ai_agent_hooks.hook_input import HookInput, is_proposed_plan, load_hook_input

from diagnostics import log_event

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
    if client == "Antigravity":
        if event_name == "SessionEnd":
            return "delete"
        if event_name == "AntigravityStatus":
            pending = hook_input.get("pending_input_count")
            if hook_input.get("tool_confirmation_pending") is True or (
                isinstance(pending, int) and pending > 0
            ):
                return "waiting"
            state = hook_input.get("agent_state")
            if state in {"thinking", "working", "tool_use", "initializing"}:
                return "running"
            if state == "idle" and hook_input.get("previous_state") != "error":
                return "idle"
            return None
        if event_name == "Stop":
            if hook_input.get("fully_idle") is False:
                return "running"
            return "idle" if hook_input.get("fully_idle") is True else None
    if event_name == "SessionStart":
        source = str(hook_input.get("source") or "")
        return "running" if client == "Claude" and source == "resume" else "idle"
    if event_name in {"PostToolUse", "UserPromptSubmit"}:
        return "running"
    if event_name == "PreToolUse":
        return None if is_codex_input_tool(hook_input, client) else "running"
    if event_name == "Notification":
        if hook_input.get("phase") == "end":
            state = hook_input.get("resume_state")
            return state if state in ("running", "idle") else None
        return "waiting"
    if event_name == "Stop":
        return "waiting" if is_proposed_plan(hook_input) else "idle"
    if event_name == "StopFailure":
        return "error"
    if event_name == "SessionEnd":
        return "idle"
    return None


def run_status(
    command: str,
    state: str,
    deadline: float | None = None,
) -> None:
    timeout = (
        STATUS_TIMEOUT_SECONDS if deadline is None else deadline - time.monotonic()
    )
    if timeout <= 0:
        return
    try:
        result = subprocess.run(
            [command, state],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        if result.returncode:
            log_event(
                "tmux.agent.hook",
                "error",
                "status_failed",
                state=state,
                exit_code=result.returncode,
                stderr=result.stderr.decode(errors="replace"),
            )
    except subprocess.TimeoutExpired:
        log_event("tmux.agent.hook", "error", "status_timeout", state=state)
    except OSError as error:
        log_event(
            "tmux.agent.hook",
            "error",
            "status_start_failed",
            reason=type(error).__name__,
        )
        raise


def update_title(
    tmux: str, hook_input: HookInput, client: str, deadline: float | None = None
) -> None:
    pane = os.environ.get("TMUX_PANE")
    session_id = hook_input.get("session_id")
    event = hook_input.get("hook_event_name")
    if not pane or not isinstance(session_id, str) or not session_id:
        return
    if event not in {
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "StatusLine",
        "SessionInfoChanged",
        "AntigravityStatus",
    }:
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
            capture_output=True,
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
        if client == "Antigravity":
            same_session = same_session and current.get("run_id") == os.environ.get(
                "ANTIGRAVITY_RUN_ID"
            )
        if event == "SessionEnd":
            if not same_session:
                return
            arguments = ["set-option", "-p", "-u", "-t", pane, option]
        else:
            if (
                event in {"UserPromptSubmit", "SessionInfoChanged"}
                and current
                and not same_session
            ):
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
            if client == "Antigravity":
                value["run_id"] = os.environ.get("ANTIGRAVITY_RUN_ID", "")
            if value == current:
                return
            arguments = ["set-option", "-p", "-t", pane, option, json.dumps(value)]
        timeout = (
            STATUS_TIMEOUT_SECONDS if deadline is None else deadline - time.monotonic()
        )
        if timeout <= 0:
            return
        result = subprocess.run(
            [tmux, *arguments],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        if result.returncode:
            log_event(
                "tmux.agent.hook",
                "error",
                "title_update_failed",
                exit_code=result.returncode,
                stderr=result.stderr.decode(errors="replace"),
            )
    except (OSError, subprocess.SubprocessError) as error:
        log_event(
            "tmux.agent.hook",
            "error",
            "title_update_failed",
            reason=type(error).__name__,
        )


def antigravity_input(tmux: str, hook_input: HookInput) -> HookInput | None:
    pane = os.environ.get("TMUX_PANE")
    run_id = os.environ.get("ANTIGRAVITY_RUN_ID")
    if not pane or not run_id or os.environ.get("TMUX_AGENT_STATUS_LOCKED") != "1":
        return None
    phase = os.environ.get("ANTIGRAVITY_LIFECYCLE")
    try:
        if phase == "start":
            subprocess.run(
                [
                    tmux,
                    "set-option",
                    "-p",
                    "-t",
                    pane,
                    "@agent_antigravity_run",
                    run_id,
                    ";",
                    "set-option",
                    "-p",
                    "-t",
                    pane,
                    "@agent_event_client",
                    "Antigravity",
                    ";",
                    "set-option",
                    "-p",
                    "-t",
                    pane,
                    "@agent_event_session",
                    run_id,
                    ";",
                    "set-option",
                    "-p",
                    "-u",
                    "-t",
                    pane,
                    "@agent_conversation",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=STATUS_TIMEOUT_SECONDS,
            )
            return {"hook_event_name": "SessionStart", "session_id": run_id}

        snapshot = (
            subprocess.run(
                [
                    tmux,
                    "display-message",
                    "-p",
                    "-t",
                    pane,
                    (
                        "#{@agent_antigravity_run}\x1f#{@agent_event_client}\x1f"
                        "#{@agent_event_session}\x1f#{@agent_state}"
                    ),
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=STATUS_TIMEOUT_SECONDS,
            )
            .stdout.rstrip("\n")
            .split("\x1f")
        )
        if len(snapshot) != 4:
            return None
        owner, client, session, previous_state = snapshot
        if owner != run_id or client != "Antigravity":
            return None
        if phase == "end":
            return {
                "hook_event_name": "SessionEnd",
                "session_id": session,
            }

        status_line = os.environ.get("ANTIGRAVITY_STATUS_LINE") == "1"
        if status_line:
            hook_input["session_id"] = hook_input.get(
                "conversation_id"
            ) or hook_input.get("session_id")
            hook_input["hook_event_name"] = "AntigravityStatus"
            hook_input["previous_state"] = previous_state
            # CLI 1.1.27 added the live conversation title to statusLine input.
            # https://antigravity.google/docs/changelog?tab=cli
            if isinstance(hook_input.get("conversation_title"), str):
                hook_input["session_title"] = hook_input["conversation_title"]
        incoming = hook_input.get("session_id")
        if not isinstance(incoming, str) or not incoming:
            return None
        if incoming != session:
            # Only the TUI observer can switch an established foreground conversation.
            if session != run_id and not status_line:
                return None
            hook_input["claim_session"] = True
        return hook_input
    except (OSError, subprocess.SubprocessError) as error:
        log_event(
            "tmux.agent.hook",
            "error",
            "ownership_update_failed",
            reason=type(error).__name__,
        )
        return None


def main() -> int:
    if os.environ.get("AI_AGENT_SUBAGENT") == "1":
        return 0

    started = time.monotonic()
    client = os.environ.get("AI_AGENT_CLIENT")
    if len(sys.argv) != 3 or not client:
        return 2

    hook_input = load_hook_input(sys.stdin.read())
    if client == "Antigravity":
        normalized = antigravity_input(sys.argv[2], hook_input)
        if normalized is None:
            return 0
        hook_input = normalized
        os.environ.setdefault("STATE_COMMAND_NAME", "agy")
    os.environ["AI_AGENT_SESSION_ID"] = str(hook_input.get("session_id") or "")
    os.environ["AI_AGENT_EVENT"] = (
        "SessionStart"
        if hook_input.get("claim_session") is True
        else str(hook_input.get("hook_event_name") or "")
    )
    if client == "Claude":
        agent_id = hook_input.get("agent_id")
        if isinstance(agent_id, str) and agent_id:
            return 0

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
