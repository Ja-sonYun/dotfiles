import argparse
import asyncio
import json
import time
from pathlib import Path
from typing import Literal

from mcp.server.fastmcp import FastMCP

from ai_agent_rules.checks import evaluate
from ai_agent_rules.code_changes import added_text, check_source_path
from ai_agent_rules.debug_log import save_log, start_log
from ai_agent_rules.guidance import RULES_GUIDANCE
from ai_agent_rules.process import with_termination
from ai_agent_rules.rule_files import (
    project_root,
    rule_path,
    rules_directory,
    write_json,
)
from ai_agent_rules.rules import (
    Rule,
    RuleDefinition,
    Target,
    effective_rules,
    load_rules,
)
from ai_agent_rules.sessions import require_session, state_lock


def change_rule(
    rules_path: Path,
    handle: str,
    name: str,
    definition: RuleDefinition | None,
) -> dict[str, object]:
    if any(rule.id == name for rule in load_rules(rules_path)):
        raise ValueError(
            "Static rule IDs are reserved and cannot be changed through MCP."
        )
    with state_lock() as metadata:
        session = require_session(metadata, handle)
        directory = rules_directory(project_root(session.cwd))
        path = rule_path(directory, name)
        if definition is None:
            try:
                path.unlink()
                removed = True
            except FileNotFoundError:
                removed = False
            return {
                "id": name,
                "source": "project",
                "path": str(path),
                "removed": removed,
            }
        write_json(path, definition.model_dump(mode="json"))
    return Rule(name, definition, "project", path).record()


def create_server(
    rules_path: Path,
    jev: str,
    debug_log: bool = False,
) -> FastMCP:
    server = FastMCP("rules", instructions=RULES_GUIDANCE)

    @server.tool()
    async def rules_list(session_handle: str) -> dict[str, object]:
        """List static and project rules, including their effective status."""
        try:
            _, rules = await asyncio.to_thread(
                effective_rules, rules_path, session_handle
            )
        except OSError as error:
            raise RuntimeError("Rule storage is unavailable.") from error
        return {"rules": [rule.record() for rule in rules]}

    @server.tool()
    async def project_rules_upsert(
        session_handle: str, id: str, rule: RuleDefinition
    ) -> dict[str, object]:
        """Add or replace a project rule at the user's request or after approval.

        For suggested rules, obtain approval of the content and project scope
        before saving. Git worktrees share .agents/rules in the main checkout;
        submodules use their own checkout and non-Git projects use their root.
        """
        log: dict[str, object] = {
            "operation": "rule_upsert",
            "started_at": time.time(),
            "status": "started",
            "session_handle": session_handle,
            "rule_id": id,
            "source": "project",
        }
        path = await asyncio.to_thread(start_log, debug_log, session_handle, log)
        try:
            result = await asyncio.to_thread(
                change_rule, rules_path, session_handle, id, rule
            )
            log["status"] = "completed"
            return result
        except asyncio.CancelledError:
            log["status"] = "cancelled"
            raise
        except OSError as error:
            raise RuntimeError("Project rule storage is unavailable.") from error
        finally:
            if log["status"] == "started":
                log["status"] = "failed"
            log["finished_at"] = time.time()
            await asyncio.to_thread(save_log, path, log)

    @server.tool()
    async def project_rules_list(session_handle: str) -> dict[str, object]:
        """List current project rules, including those overridden by static rules."""
        try:
            cwd, rules = await asyncio.to_thread(
                effective_rules, rules_path, session_handle
            )
            root = await asyncio.to_thread(project_root, cwd)
            directory = await asyncio.to_thread(rules_directory, root)
        except OSError as error:
            raise RuntimeError("Project rule storage is unavailable.") from error
        return {
            "path": str(directory),
            "rules": [rule.record() for rule in rules if rule.source == "project"],
        }

    @server.tool()
    async def project_rules_remove(session_handle: str, id: str) -> dict[str, object]:
        """Remove a project rule from the current project."""
        try:
            return await asyncio.to_thread(
                change_rule, rules_path, session_handle, id, None
            )
        except OSError as error:
            raise RuntimeError("Project rule storage is unavailable.") from error

    @server.tool()
    async def rules_check(
        session_handle: str,
        target: Target,
        text: str | None = None,
        path: str | None = None,
        input_kind: Literal["code", "patch"] = "code",
        tool_name: str | None = None,
        tool_input: dict[str, object] | str | None = None,
    ) -> dict[str, object]:
        """Check supplied material during a task without executing it.

        For code, supply one file's text and path, relative to the session cwd
        or absolute. Set input_kind to patch for an apply_patch or unified patch.
        Regex checks inspect only added text; intent checks retain patch context.
        For tool, supply tool_name and tool_input; text is optional context.
        For task, supply a plan, decision, explanation, or response draft as text.
        Evaluates enabled, effective rules whose target, extension, and trigger
        match. Intent uses supplied evidence and project instructions.
        Returns status: completed, incomplete, or skipped, with feedback only
        for violations, uncertain verdicts, or failures.
        Completed means the check finished, not that the material is compliant.
        Detailed scores and results remain in debug logs when enabled; feedback
        includes the log path. Skipped means no rules pass the selection conditions.
        """
        if target == "tool":
            if tool_name is None or not tool_name.strip() or tool_input is None:
                raise ValueError("Tool checks require tool_name and tool_input.")
        elif tool_name is not None or tool_input is not None:
            raise ValueError("Only tool checks accept tool_name and tool_input.")
        if target != "tool" and text is None:
            raise ValueError("Code and task checks require text.")
        if target != "code" and input_kind != "code":
            raise ValueError("Only code checks accept patch input.")
        if target == "code" and (path is None or not path.strip()):
            raise ValueError("Code checks require a file path.")
        if target != "code" and path is not None:
            raise ValueError("Only code checks accept a file path.")
        try:
            cwd, rules = await asyncio.to_thread(
                effective_rules, rules_path, session_handle
            )
            source = cwd / f".{target}"
            if target == "code" and path is not None:
                source = await asyncio.to_thread((cwd / path).resolve)
                check_source_path(source)
                _, rules = await asyncio.to_thread(
                    effective_rules, rules_path, session_handle, source.parent
                )
            applicable = [rule for rule in rules if rule.applies(target, source)]
        except OSError as error:
            raise RuntimeError(
                "Cannot read the rules or resolve the inspection path."
            ) from error
        state = {"text": text if text is not None else "", "cwd": str(cwd)}
        regex_text = state["text"]
        if target == "code":
            state.update(path=str(source), input_kind=input_kind)
            if input_kind == "patch":
                regex_text = added_text(state["text"])
        elif target == "tool" and tool_name is not None:
            state.update(
                tool_name=tool_name,
                tool_input=json.dumps(tool_input, ensure_ascii=False),
            )
        result = await evaluate(
            jev,
            applicable,
            state,
            cwd,
            time.monotonic() + 30,
            context_path=source,
            regex_text=regex_text,
            session_handle=session_handle,
            debug_log=debug_log,
        )
        if result.errors or result.halted:
            status = "incomplete"
        elif not result.applicable_rule_count:
            status = "skipped"
        else:
            status = "completed"
        response: dict[str, object] = {"status": status}
        feedback = result.feedback(f"{target} check")
        if feedback:
            response["feedback"] = feedback
        return response

    return server


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rules", required=True, type=Path)
    parser.add_argument("--jev", required=True)
    parser.add_argument("--debug-log", action="store_true")
    args = parser.parse_args()
    server = create_server(args.rules, args.jev, args.debug_log)
    try:
        asyncio.run(with_termination(server.run_stdio_async()))
    except (asyncio.CancelledError, KeyboardInterrupt):
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
