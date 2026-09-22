import argparse
import fnmatch
import json
import os
import sys
from pathlib import Path
from typing import Literal, TypedDict

from ai_agent_hooks.edit_input import edit_targets

Decision = Literal["allow", "ask", "deny"]
Access = Literal["allow", "deny"]
PRIORITY = {"allow": 0, "ask": 1, "deny": 2}


class FileRule(TypedDict):
    path: str
    excludes: list[str]
    read: Access | None
    write: Access | None


class Files(TypedDict):
    rules: list[FileRule]


class Server(TypedDict):
    default: Decision | None
    tools: dict[str, Decision]


class Policy(TypedDict):
    files: Files
    mcp: dict[str, Server]
    claudePlugin: str


def match_path(path: tuple[str, ...], pattern: tuple[str, ...]) -> bool:
    if not pattern:
        return not path
    if pattern[0] == "**":
        return any(
            match_path(path[index:], pattern[1:]) for index in range(len(path) + 1)
        )
    return (
        bool(path)
        and fnmatch.fnmatchcase(path[0], pattern[0])
        and match_path(path[1:], pattern[1:])
    )


def file_decision(
    path: Path, operation: Literal["read", "write"], cwd: Path, policy: Files
) -> Access | None:
    path = path.expanduser()
    candidates = {Path(os.path.abspath(path)), path.resolve()}
    matches: list[Access] = []
    for rule in policy["rules"]:
        value = rule[operation]
        if value is None:
            continue
        pattern = Path(os.path.expanduser(rule["path"]))
        if not pattern.is_absolute():
            pattern = cwd / pattern
        patterns = {pattern, pattern.resolve()}

        exclusions: list[Path] = []
        for excluded in rule["excludes"]:
            exclusion = Path(os.path.expanduser(excluded))
            if not exclusion.is_absolute():
                exclusion = cwd / exclusion
            exclusions.append(Path(os.path.abspath(exclusion)))

        if any(
            any(match_path(candidate.parts, entry.parts) for entry in patterns)
            and not any(
                match_path(candidate.parts, exclusion.parts) for exclusion in exclusions
            )
            for candidate in candidates
        ):
            matches.append(value)
    return max(matches, key=PRIORITY.__getitem__) if matches else None


def mcp_decision(server: str, tool: str, policy: Policy) -> Decision | None:
    entry = policy["mcp"].get(server)
    if entry is None or not tool:
        return None
    return entry["tools"].get(tool, entry["default"])


def decide(hook: dict[str, object], policy: Policy, client: str) -> Decision | None:
    tool = str(hook.get("tool_name") or "").removeprefix("functions.")
    data = hook.get("tool_input")
    cwd = Path(str(hook.get("cwd") or Path.cwd()))

    if client == "Claude" and tool.startswith("mcp__"):
        matches = []
        for server in policy["mcp"]:
            for prefix in (
                f"mcp__{server}__",
                f"mcp__plugin_{policy['claudePlugin']}_{server}__",
            ):
                if tool.startswith(prefix):
                    matches.append((server, tool[len(prefix) :]))
        if not matches:
            return None
        if len(matches) != 1:
            return "deny"
        return mcp_decision(*matches[0], policy)

    tool = tool.lower()
    if not policy["files"]["rules"]:
        return None

    if tool in {"read", "read_file", "view_image"}:
        if not isinstance(data, dict):
            return "deny"
        path = data.get("file_path", data.get("path"))
        if not isinstance(path, str) or not path:
            return "deny"
        return file_decision(
            cwd / Path(path).expanduser(), "read", cwd, policy["files"]
        )

    if tool in {
        "write",
        "edit",
        "multiedit",
        "notebookedit",
        "write_file",
        "edit_file",
        "apply_patch",
    }:
        targets = edit_targets(hook, resolve_paths=False)
        if not targets:
            return "deny"
        decisions = [
            file_decision(path, "write", cwd, policy["files"])
            for target in targets
            for path in (target.before, target.after)
        ]
        if "deny" in decisions:
            return "deny"
        return "allow" if all(value == "allow" for value in decisions) else None
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    client = os.environ.get("AI_AGENT_CLIENT", "")
    reason = "Tool call rejected by the shared AI agent permissions."
    try:
        with args.config.open(encoding="utf-8") as stream:
            policy: Policy = json.load(stream)
        hook = json.load(sys.stdin)
        if not isinstance(hook, dict):
            raise TypeError("Expected a tool call object.")
        decision = decide(hook, policy, client)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        decision = "deny"
        reason = f"Cannot evaluate the shared AI agent permissions: {error}"

    # Codex approvals come from native command and MCP rules, not hook decisions.
    if decision is None or (client == "Codex" and decision != "deny"):
        return 0
    if decision == "ask":
        reason = (
            "This tool call requires approval under the shared AI agent permissions."
        )
    elif decision == "allow":
        reason = "Tool call allowed by the shared AI agent permissions."
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": decision,
                    "permissionDecisionReason": reason,
                },
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
