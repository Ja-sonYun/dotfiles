import argparse
import asyncio
import json
import re
import sys
import time
from pathlib import Path

from ai_agent_hooks.edit_input import edit_targets
from ai_agent_hooks.hook_input import HookInput, emit_feedback, load_hook_input

from ai_agent_jev.code_changes import inspections, project_instructions
from ai_agent_jev.coding_rules import effective_rules, evaluate
from ai_agent_jev.process import run_process, with_termination
from ai_agent_jev.sessions import end_session, register_session


def session_guidance(handle: str) -> str:
    return (
        f"Jev session_handle: {handle}\n"
        "Use this exact handle with the jev-rules MCP tools: rules_upsert, rules_list, "
        "rules_remove, rules_check, project_rules_upsert, project_rules_list, "
        "project_rules_remove, and rules_promote_to_project. Proactively suggest "
        "reusable rules from explicit user preferences, repeated corrections, and "
        "constraints that apply to future work. Exclude one-off task instructions "
        "and check existing rules before suggesting a candidate. If a candidate "
        "overlaps an existing rule, propose an update instead of a duplicate. "
        "Suggest at most one candidate per turn and do not repeat rejected "
        "candidates in the same session. Show the proposed rule text, target "
        "(code, tool, or task), and scope (session or project). Extract only the "
        "reusable instruction, not the whole conversation. Save a suggested rule "
        "only after the user approves its content and scope, using rules_upsert "
        "for session rules or project_rules_upsert for project rules. Other rule "
        "changes also require a user request or approval. Static rule IDs are "
        "reserved. Session rules override "
        "project rules, including when disabled. Git project rules are JSON files "
        "in <git-common-dir>/ai-agent/jev/rules, shared across the repository's "
        "worktrees and not included in commits. Non-Git projects use .agents/rules. "
        "Session rules are stored in "
        ".agents/session-rules/<session_handle> in the initial project. Rule IDs may "
        "contain only letters, digits, underscores, and hyphens. Specify target as "
        "code, tool, or task. Promotion saves a project rule before removing the "
        "session original; replacing an existing project rule requires replace=true. "
        "Use rules_check during a task to inspect supplied code, proposed tool calls, "
        "or task material. Pass target and text; code checks also require path. "
        "Before sending a final response, use rules_check with target=task and its "
        "draft as text, and apply the feedback. Feedback does not block tool execution "
        "or completion."
    )


def is_rules_tool(hook_input: HookInput) -> bool:
    names = [hook_input.get("tool_name")]
    tool_input = hook_input.get("tool_input")
    if isinstance(tool_input, dict):
        names.extend(tool_input.get(key) for key in ("name", "tool", "toolName"))
    return any(
        isinstance(name, str)
        and re.search(
            r"(?:^|[._])(?:project_)?rules_"
            r"(?:upsert|list|remove|check|promote_to_project)$",
            name,
        )
        for name in names
    )


async def check_changes(
    hook_input: HookInput,
    rules_path: Path,
    handle: str | None,
    jev: str,
    debug_log: bool = False,
) -> list[str]:
    regions, notes = await asyncio.to_thread(inspections, hook_input)
    deadline = time.monotonic() + 30
    halted = False
    for region in regions:
        if halted:
            notes.append(f"[Jev not checked] {region.path}: an earlier request failed")
            continue
        try:
            _, rules = await asyncio.to_thread(
                effective_rules, rules_path, handle, region.path.parent
            )
            applicable = [rule for rule in rules if rule.applies(region.path)]
            if not applicable:
                continue
            context = await asyncio.to_thread(project_instructions, region.path)
        except (OSError, TypeError, ValueError) as error:
            notes.append(
                f"[Jev not checked] {region.path}: cannot load rules or context ({error})"
            )
            continue
        result = await evaluate(
            jev,
            applicable,
            {
                "path": str(region.path),
                "input_kind": region.kind,
                "code": region.code,
                "project_instructions": context,
            },
            Path(str(hook_input.get("cwd") or Path.cwd())),
            deadline,
            session_handle=handle,
            debug_log=debug_log,
        )
        feedback = result.feedback(f"{region.path} (editing tool input)")
        notes.extend(feedback)
        halted = result.halted
    return notes


async def handle_event(
    hook_input: HookInput,
    rules_path: Path,
    jev: str,
    post_edit_command: str | None,
    notes: list[str],
    debug_log: bool = False,
) -> None:
    event = hook_input.get("hook_event_name")
    if event not in {"SessionStart", "PreToolUse", "PostToolUse", "SessionEnd"}:
        return
    response = hook_input.get("tool_response")
    if event == "PostToolUse" and (
        hook_input.get("tool_failed") is True
        or (isinstance(response, dict) and response.get("isError"))
    ):
        return
    if event == "SessionEnd":
        try:
            await asyncio.to_thread(end_session, hook_input)
        except (OSError, TypeError, ValueError):
            print("[Jev cleanup failed] Cannot remove session state.", file=sys.stderr)
        return

    try:
        handle, created = await asyncio.to_thread(register_session, hook_input)
    except (OSError, TypeError, ValueError):
        handle, created = None, False
        notes.append("[Jev not checked] Session storage is unavailable.")
    if handle is not None and (created or event == "SessionStart"):
        notes.append(session_guidance(handle))
    elif handle is None:
        notes.append("[Jev session rules unavailable] Missing agent or session ID.")
    if event == "SessionStart":
        return

    cwd = Path(str(hook_input.get("cwd") or Path.cwd()))
    if event == "PreToolUse":
        if is_rules_tool(hook_input):
            return
        try:
            _, rules = await asyncio.to_thread(effective_rules, rules_path, handle, cwd)
            applicable = [
                rule
                for rule in rules
                if rule.effective
                and rule.definition.enable
                and rule.definition.target == "tool"
            ]
            if not applicable:
                return
            context = await asyncio.to_thread(project_instructions, cwd / ".tool-call")
        except (OSError, TypeError, ValueError) as error:
            notes.append(
                f"[Jev not checked] Cannot load tool rules or context ({error})"
            )
            return
        result = await evaluate(
            jev,
            applicable,
            {
                "tool_name": str(hook_input.get("tool_name") or ""),
                "tool_input": json.dumps(
                    hook_input.get("tool_input"), ensure_ascii=False
                ),
                "cwd": str(cwd),
                "project_instructions": context,
            },
            cwd,
            time.monotonic() + 30,
            session_handle=handle,
            debug_log=debug_log,
        )
        feedback = result.feedback("Proposed tool call")
        notes.extend(feedback)
    elif edit_targets(hook_input):
        if post_edit_command is not None:
            try:
                output = await run_process(
                    [post_edit_command], cwd, 125, json.dumps(hook_input)
                )
                if output.strip():
                    result = json.loads(output)
                    specific = (
                        result.get("hookSpecificOutput")
                        if isinstance(result, dict)
                        else None
                    )
                    if not isinstance(specific, dict) or not isinstance(
                        specific.get("additionalContext"), str
                    ):
                        raise ValueError("Invalid format and lint output.")
                    notes.append(specific["additionalContext"])
            except (OSError, RuntimeError, TimeoutError, ValueError):
                notes.append(
                    "[Format and lint checks failed] The formatter/lint command did not return a valid result."
                )
        notes.extend(
            await check_changes(hook_input, rules_path, handle, jev, debug_log)
        )


async def process_event(
    hook_input: HookInput,
    rules_path: Path,
    jev: str,
    post_edit_command: str | None,
    debug_log: bool = False,
) -> None:
    notes: list[str] = []
    await handle_event(hook_input, rules_path, jev, post_edit_command, notes, debug_log)
    emit_feedback(str(hook_input.get("hook_event_name")), notes)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rules", required=True, type=Path)
    parser.add_argument("--jev", required=True)
    parser.add_argument("--post-edit-command")
    parser.add_argument("--debug-log", action="store_true")
    args = parser.parse_args()
    raw_input = sys.stdin.read()
    hook_input = load_hook_input(raw_input)
    try:
        asyncio.run(
            with_termination(
                process_event(
                    hook_input,
                    args.rules,
                    args.jev,
                    args.post_edit_command,
                    args.debug_log,
                )
            )
        )
    except (asyncio.CancelledError, KeyboardInterrupt):
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
