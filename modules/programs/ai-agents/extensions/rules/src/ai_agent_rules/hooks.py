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
from ai_agent_rules.edit_context import capture_context, clear_context, take_context
from ai_agent_rules.guidance import RULES_GUIDANCE
from ai_agent_rules.process import run_process, with_termination
from ai_agent_rules.rules import effective_rules
from ai_agent_rules.sessions import end_session, register_session


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
) -> list[str]:
    regions, notes = await asyncio.to_thread(inspections, hook_input, matching_texts)
    deadline = time.monotonic() + 30
    halted = False
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
        halted = halted or result.halted
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
    failed = hook_input.get("tool_failed") is True or (
        isinstance(response, dict) and response.get("isError")
    )
    matching_texts = None
    if event == "PostToolUse":
        try:
            matching_texts = await asyncio.to_thread(
                take_context, hook_input, failed=bool(failed)
            )
        except (OSError, TypeError, ValueError) as error:
            notes.append(
                f"[Rules not checked] Replacement context unavailable ({error})"
            )
        if failed:
            return
    if event == "SessionEnd":
        try:
            await asyncio.to_thread(clear_context, hook_input)
            await asyncio.to_thread(end_session, hook_input)
        except (OSError, TypeError, ValueError):
            print(
                "[Rules cleanup failed] Cannot remove session state.", file=sys.stderr
            )
        return

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
        return

    if event == "PreToolUse":
        if is_rules_tool(hook_input):
            return
        try:
            await asyncio.to_thread(capture_context, hook_input)
        except (OSError, TypeError, ValueError) as error:
            notes.append(
                f"[Rules not checked] Cannot capture replacement context ({error})"
            )
        try:
            _, rules = await asyncio.to_thread(effective_rules, rules_path, handle, cwd)
            applicable = [rule for rule in rules if rule.applies("tool")]
            if not applicable:
                return
        except (OSError, TypeError, ValueError) as error:
            notes.append(f"[Rules not checked] Cannot load tool rules ({error})")
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
            },
            cwd,
            time.monotonic() + 30,
            context_path=cwd / ".tool-call",
            session_handle=handle,
            debug_log=debug_log,
        )
        notes.extend(result.feedback("Proposed tool call"))
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
            await check_changes(
                hook_input, rules_path, handle, jev, debug_log, matching_texts
            )
        )


async def process_event(
    hook_input: HookInput,
    rules_path: Path,
    jev: str,
    post_edit_command: str | None,
    debug_log: bool = False,
) -> None:
    notes: list[str] = []
    await handle_event(
        hook_input,
        rules_path,
        jev,
        post_edit_command,
        notes,
        debug_log,
    )
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
