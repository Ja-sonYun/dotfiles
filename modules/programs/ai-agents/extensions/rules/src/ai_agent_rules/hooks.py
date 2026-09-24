import argparse
import asyncio
import json
import re
import sys
import time
from pathlib import Path

from ai_agent_hooks.edit_input import edit_targets
from ai_agent_hooks.hook_input import HookInput, emit_feedback, load_hook_input

from ai_agent_rules.checks import evaluate
from ai_agent_rules.code_changes import inspections
from ai_agent_rules.edit_context import capture_context
from ai_agent_rules.guidance import RULES_GUIDANCE
from ai_agent_rules.process import with_termination
from ai_agent_rules.rules import effective_rules
from ai_agent_rules.sessions import end_session, record_rejection, register_session


def is_rules_tool(hook_input: HookInput) -> bool:
    names = [hook_input.get("tool_name")]
    tool_input = hook_input.get("tool_input")
    if isinstance(tool_input, dict):
        names.extend(tool_input.get(key) for key in ("name", "tool", "toolName"))
    return any(
        isinstance(name, str)
        and re.search(
            r"(?:^|[._])(?:rules_(?:list|check)|project_rules_(?:upsert|list|remove))$",
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
    matching_texts: list[str] | None = None,
) -> tuple[list[str], bool]:
    """Return feedback and whether any code rule reported a confirmed violation."""
    regions, notes = await asyncio.to_thread(inspections, hook_input, matching_texts)
    deadline = time.monotonic() + 30
    halted = False
    violated = False
    for region in regions:
        try:
            _, rules = await asyncio.to_thread(
                effective_rules, rules_path, handle, region.path.parent
            )
            applicable = [rule for rule in rules if rule.applies("code", region.path)]
            if not applicable:
                continue
        except (OSError, TypeError, ValueError) as error:
            notes.append(
                f"[Rules not checked] {region.path}: cannot load rules ({error})"
            )
            continue
        try:
            regex_text = region.matching_text()
        except ValueError as error:
            independent = [
                rule
                for rule in applicable
                if rule.definition.check.regex is None
                and rule.definition.trigger.pattern is None
            ]
            if len(independent) != len(applicable):
                notes.append(f"[Rules not checked] {region.path}: {error}")
            applicable = independent
            regex_text = ""
        if not applicable:
            continue
        result = await evaluate(
            jev,
            applicable,
            {
                "path": str(region.path),
                "input_kind": region.kind,
                "code": region.code,
            },
            Path(str(hook_input.get("cwd") or Path.cwd())),
            deadline,
            context_path=region.path,
            regex_text=regex_text,
            intent_halted=halted,
            session_handle=handle,
            debug_log=debug_log,
        )
        notes.extend(result.feedback(f"{region.path} (editing tool input)"))
        violated = violated or any(
            item["verdict"] == "violation" for item in result.results
        )
        halted = halted or result.halted
    return notes, violated


async def handle_event(
    hook_input: HookInput,
    rules_path: Path,
    jev: str,
    notes: list[str],
    debug_log: bool = False,
) -> str | None:
    """Collect event feedback and return a reason when the proposed edit is denied."""
    event = hook_input.get("hook_event_name")
    if event not in {"SessionStart", "PreToolUse", "PostToolUse", "SessionEnd"}:
        return None
    response = hook_input.get("tool_response")
    failed = hook_input.get("tool_failed") is True or (
        isinstance(response, dict) and response.get("isError")
    )
    if event == "PostToolUse" and failed:
        return None
    if event == "SessionEnd":
        try:
            await asyncio.to_thread(end_session, hook_input)
        except (OSError, TypeError, ValueError):
            print(
                "[Rules cleanup failed] Cannot remove session state.", file=sys.stderr
            )
        return None

    try:
        handle, created = await asyncio.to_thread(register_session, hook_input)
    except (OSError, TypeError, ValueError):
        handle, created = None, False
        notes.append("[Rules not checked] Session storage is unavailable.")
    if handle is not None and (created or event == "SessionStart"):
        notes.append(f"Rules session_handle: {handle}\n{RULES_GUIDANCE}")
    elif handle is None:
        notes.append("[Rules session unavailable] Missing agent or session ID.")
    cwd = Path(str(hook_input.get("cwd") or Path.cwd()))
    if event == "SessionStart":
        return None

    if event == "PreToolUse":
        if is_rules_tool(hook_input):
            return None
        try:
            _, rules = await asyncio.to_thread(effective_rules, rules_path, handle, cwd)
            applicable = [rule for rule in rules if rule.applies("tool")]
        except (OSError, TypeError, ValueError) as error:
            notes.append(f"[Rules not checked] Cannot load tool rules ({error})")
            applicable = []
        if applicable:
            result = await evaluate(
                jev,
                applicable,
                {
                    "tool_name": str(hook_input.get("tool_name") or ""),
                    "tool_input": json.dumps(
                        hook_input.get("tool_input"), ensure_ascii=False
                    ),
                    "cwd": str(cwd),
                },
                cwd,
                time.monotonic() + 30,
                context_path=cwd / ".tool-call",
                session_handle=handle,
                debug_log=debug_log,
            )
            notes.extend(result.feedback("Proposed tool call"))

        if edit_targets(hook_input):
            matching_texts = None
            try:
                matching_texts = await asyncio.to_thread(capture_context, hook_input)
            except (OSError, TypeError, ValueError) as error:
                notes.append(
                    f"[Rules not checked] Cannot capture replacement context ({error})"
                )
            feedback, violated = await check_changes(
                hook_input, rules_path, handle, jev, debug_log, matching_texts
            )
            notes.extend(feedback)
            if violated:
                repeated = False
                if handle is not None:
                    try:
                        repeated = await asyncio.to_thread(
                            record_rejection, handle, hook_input
                        )
                    except (OSError, TypeError, ValueError) as error:
                        notes.append(
                            f"[Rules retry unavailable] Cannot record this edit ({error})"
                        )
                if not repeated:
                    return (
                        "Code rules rejected this edit. Review the feedback before "
                        "retrying. An identical retry in this session bypasses this "
                        "rules rejection when the rejection was recorded."
                    )
                notes.append(
                    "[Rules retry] This identical edit was already rejected in this "
                    "session. Rules will not block it again; other permission "
                    "checks still apply."
                )
    return None


async def process_event(
    hook_input: HookInput,
    rules_path: Path,
    jev: str,
    debug_log: bool = False,
) -> None:
    notes: list[str] = []
    deny_reason = await handle_event(
        hook_input,
        rules_path,
        jev,
        notes,
        debug_log,
    )
    emit_feedback(
        str(hook_input.get("hook_event_name")), notes, deny_reason=deny_reason
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rules", required=True, type=Path)
    parser.add_argument("--jev", required=True)
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
                    args.debug_log,
                )
            )
        )
    except (asyncio.CancelledError, KeyboardInterrupt):
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
