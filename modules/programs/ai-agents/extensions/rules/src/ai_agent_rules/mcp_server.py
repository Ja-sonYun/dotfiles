import argparse
import asyncio
import time
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from ai_agent_rules.checks import evaluate
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
    async def rules_check(session_handle: str, text: str) -> dict[str, object]:
        """Check a plan, decision, explanation, or response draft without executing it.

        Supply task material as text. Code and tool checks run automatically
        through hooks. Evaluates enabled, effective task rules whose extension
        and trigger match. Intent uses supplied evidence and project instructions.
        Returns status: completed, incomplete, or skipped, with feedback only
        for violations, uncertain verdicts, or failures.
        Completed means the check finished, not that the material is compliant.
        Detailed scores and results remain in debug logs when enabled; feedback
        includes the log path. Skipped means no rules pass the selection conditions.
        """
        try:
            cwd, rules = await asyncio.to_thread(
                effective_rules, rules_path, session_handle
            )
            source = cwd / ".task"
            applicable = [rule for rule in rules if rule.applies("task", source)]
        except OSError as error:
            raise RuntimeError("Cannot read the rules.") from error
        result = await evaluate(
            jev,
            applicable,
            {"text": text, "cwd": str(cwd)},
            cwd,
            time.monotonic() + 30,
            context_path=source,
            regex_text=text,
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
        feedback = result.feedback("task check")
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
