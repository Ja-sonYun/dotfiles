import argparse
import asyncio
import time
from pathlib import Path
from typing import Literal

from mcp.server.fastmcp import FastMCP

from ai_agent_jev.code_changes import check_source_path, project_instructions
from ai_agent_jev.coding_rules import (
    Rule,
    RuleDefinition,
    Target,
    effective_rules,
    evaluate,
    load_rules,
)
from ai_agent_jev.process import with_termination
from ai_agent_jev.rule_files import (
    project_root,
    read_json,
    rule_path,
    rules_directory,
    write_json,
)
from ai_agent_jev.sessions import require_session, state_lock


def change_rule(
    rules_path: Path,
    handle: str,
    name: str,
    definition: RuleDefinition | None,
    scope: Literal["session", "project"],
) -> dict[str, object]:
    if any(rule.id == name for rule in load_rules(rules_path)):
        raise ValueError(
            "Static rule IDs are reserved and cannot be changed through MCP."
        )
    with state_lock() as metadata:
        session = require_session(metadata, handle)
        root = project_root(session.cwd) if scope == "project" else session.root
        directory = rules_directory(root, handle if scope == "session" else None)
        path = rule_path(directory, name)
        if definition is None:
            try:
                path.unlink()
                removed = True
            except FileNotFoundError:
                removed = False
            return {"id": name, "source": scope, "path": str(path), "removed": removed}
        write_json(path, definition.model_dump(mode="json"))
        effective = (
            scope == "session"
            or not rule_path(rules_directory(session.root, handle), name).exists()
        )
    return Rule(name, definition, scope, path, effective).record()


def promote_rule(
    rules_path: Path, handle: str, name: str, replace: bool
) -> dict[str, object]:
    if any(rule.id == name for rule in load_rules(rules_path)):
        raise ValueError(
            "Static rule IDs are reserved and cannot be changed through MCP."
        )
    with state_lock() as metadata:
        session = require_session(metadata, handle)
        source = rule_path(rules_directory(session.root, handle), name)
        destination = rule_path(rules_directory(project_root(session.cwd)), name)
        try:
            definition = RuleDefinition.model_validate(read_json(source))
        except FileNotFoundError as error:
            raise ValueError(f"Session rule does not exist: {name}") from error
        except ValueError as error:
            raise ValueError(f"Invalid session rule: {name}") from error
        if destination.exists() and not replace:
            raise ValueError(
                "Project rule already exists; set replace=true to overwrite it."
            )
        write_json(destination, definition.model_dump(mode="json"))
        try:
            source.unlink()
        except OSError as error:
            raise RuntimeError(
                f"Project rule saved to {destination}, but the session rule could not be "
                "removed. Both copies have been preserved."
            ) from error
    return Rule(name, definition, "project", destination).record()


def create_server(rules_path: Path, jev: str, debug_log: bool = False) -> FastMCP:
    server = FastMCP(
        "jev-rules",
        instructions=(
            "Use the session_handle supplied by the session hook for every call. "
            "Proactively suggest reusable rules from explicit user preferences, "
            "repeated corrections, and constraints for future work. Exclude "
            "one-off task instructions and check existing rules first; propose "
            "updates for overlapping rules rather than duplicates. Suggest at "
            "most one candidate per turn and do not repeat rejected candidates "
            "in the same session. Show the rule text, target (code, tool, or "
            "task), and scope (session or project), not the whole conversation. "
            "Save suggested rules only after the user approves their content "
            "and scope. Use rules_upsert for session rules and "
            "project_rules_upsert for project rules. Other rule changes also "
            "require a user request or approval. "
            "Static rule IDs are reserved. Session rules override project rules. "
            "Project tools use the session's current working directory. "
            "Git project rules are shared across worktrees in "
            "<git-common-dir>/ai-agent/jev/rules and are not included in commits. "
            "Non-Git projects use .agents/rules. "
            "Use rules_check during a task for code, tool calls, or task material. "
            "Check final response drafts with target=task and consider its feedback."
        ),
    )

    @server.tool()
    async def rules_upsert(
        session_handle: str, id: str, rule: RuleDefinition
    ) -> dict[str, object]:
        """Add or replace a session rule at the user's request or after approval.

        For suggested rules, obtain approval of the content and session scope
        before saving. Target is required and static IDs are reserved.
        """
        try:
            return await asyncio.to_thread(
                change_rule, rules_path, session_handle, id, rule, "session"
            )
        except OSError as error:
            raise RuntimeError("Session rule storage is unavailable.") from error

    @server.tool()
    async def rules_list(session_handle: str) -> dict[str, object]:
        """List all rules with source, file path, enabled state, and effective selection."""
        try:
            _, rules = await asyncio.to_thread(
                effective_rules, rules_path, session_handle
            )
        except OSError as error:
            raise RuntimeError("Rule storage is unavailable.") from error
        return {"rules": [rule.record() for rule in rules]}

    @server.tool()
    async def rules_remove(session_handle: str, id: str) -> dict[str, object]:
        """Remove a session rule, revealing any project rule with the same ID."""
        try:
            return await asyncio.to_thread(
                change_rule, rules_path, session_handle, id, None, "session"
            )
        except OSError as error:
            raise RuntimeError("Session rule storage is unavailable.") from error

    @server.tool()
    async def project_rules_upsert(
        session_handle: str, id: str, rule: RuleDefinition
    ) -> dict[str, object]:
        """Add or replace a project rule at the user's request or after approval.

        For suggested rules, obtain approval of the content and project scope
        before saving. Git projects share <git-common-dir>/ai-agent/jev/rules
        across worktrees; non-Git projects use .agents/rules.
        """
        try:
            return await asyncio.to_thread(
                change_rule, rules_path, session_handle, id, rule, "project"
            )
        except OSError as error:
            raise RuntimeError("Project rule storage is unavailable.") from error

    @server.tool()
    async def project_rules_list(session_handle: str) -> dict[str, object]:
        """List current project rules, including those overridden by session rules."""
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
        """Remove a project rule without removing a session override."""
        try:
            return await asyncio.to_thread(
                change_rule, rules_path, session_handle, id, None, "project"
            )
        except OSError as error:
            raise RuntimeError("Project rule storage is unavailable.") from error

    @server.tool()
    async def rules_promote_to_project(
        session_handle: str, id: str, replace: bool = False
    ) -> dict[str, object]:
        """Save a session rule to the current project, then remove the session original.

        Existing project rules require replace=true. A failed save preserves the
        session rule; a failed removal preserves both copies and reports an error.
        """
        try:
            return await asyncio.to_thread(
                promote_rule, rules_path, session_handle, id, replace
            )
        except OSError as error:
            raise RuntimeError(
                "Cannot save the project rule; the session rule remains."
            ) from error

    @server.tool()
    async def rules_check(
        session_handle: str, target: Target, text: str, path: str | None = None
    ) -> dict[str, object]:
        """Check supplied material during a task without executing it.

        For code, supply one file's code or patch as text and its path, relative to
        the session cwd or absolute. Other targets do not accept a path.
        For tool, include the proposed tool name and
        arguments in text. For task, supply a plan, decision, explanation, or
        response draft. Only supplied evidence and project instructions are used.
        Returns applicable_rule_count, results, and errors as advisory feedback.
        """
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
            applicable = [
                rule
                for rule in rules
                if rule.effective
                and rule.definition.enable
                and rule.definition.target == target
                and (target != "code" or rule.applies(source))
            ]
            context = (
                await asyncio.to_thread(project_instructions, source)
                if applicable
                else ""
            )
        except OSError as error:
            raise RuntimeError(
                "Cannot read the rules or inspection context."
            ) from error
        state = {"text": text, "cwd": str(cwd), "project_instructions": context}
        if target == "code":
            state["path"] = str(source)
        result = await evaluate(
            jev,
            applicable,
            state,
            cwd,
            time.monotonic() + 30,
            session_handle=session_handle,
            debug_log=debug_log,
        )
        return {
            "applicable_rule_count": result.applicable_rule_count,
            "results": result.results,
            "errors": result.errors,
        }

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
