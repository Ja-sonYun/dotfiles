import argparse
import asyncio
import hashlib
import json
import sys
import time
from dataclasses import replace
from pathlib import Path
from typing import Literal, Self

import httpx
from ai_agent_hooks.edit_input import edit_targets, is_edit_tool
from ai_agent_hooks.hook_input import HookInput
from pydantic import BaseModel, ConfigDict, Field, model_validator

from ai_agent_rules.checks import evaluate
from ai_agent_rules.code_changes import inspections, project_instructions
from ai_agent_rules.edit_context import capture_context
from ai_agent_rules.rule_files import project_root, read_rules, rules_directory
from ai_agent_rules.rules import Rule, load_rules, parse_rules


class Request(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    client: Literal["codex", "claude", "pi"]
    cwd: str
    tool_name: str
    tool_input: dict[str, object]
    context: dict[str, object] = Field(default_factory=dict)
    additionalRules: dict[str, object] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_context(self) -> Self:
        if self.context.keys() & {"client", "cwd", "tool_name", "tool_input"}:
            raise ValueError("Context must not override tool call fields.")
        return self


def applicable_rules(path: Path, cwd: Path, additional: list[Rule]) -> list[Rule]:
    static = load_rules(path)
    directory = rules_directory(project_root(cwd))
    project = parse_rules(read_rules(directory), "project", directory)
    static_ids = {rule.id for rule in static}
    if {rule.id for rule in additional} & {rule.id for rule in [*static, *project]}:
        raise ValueError("Additional rule IDs must not collide with configured rules.")
    return [
        *static,
        *(replace(rule, effective=rule.id not in static_ids) for rule in project),
        *additional,
    ]


async def check(
    request: Request, rules_path: Path, api: httpx.AsyncClient
) -> dict[str, object]:
    cwd = Path(request.cwd).resolve()
    additional = parse_rules(request.additionalRules, "caller")
    rules = applicable_rules(rules_path, cwd, additional)
    state = {
        key: value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
        for key, value in request.context.items()
    }
    state.update(
        client=request.client,
        cwd=str(cwd),
        tool_name=request.tool_name,
        tool_input=json.dumps(request.tool_input, ensure_ascii=False),
    )
    deadline = time.monotonic() + 30
    result = await evaluate(
        api,
        [rule for rule in rules if rule.applies("tool", request.client)],
        state,
        cwd,
        deadline,
        context_path=cwd / "AGENTS.md",
        require_complete_input=True,
    )
    records: list[object] = [request.client, *(rule.record() for rule in rules)]
    records.append(project_instructions(cwd / "AGENTS.md"))
    if is_edit_tool(request.tool_name):
        hook_input: HookInput = {
            "cwd": str(cwd),
            "tool_name": request.tool_name,
            "tool_input": request.tool_input,
        }
        try:
            if not edit_targets(hook_input):
                raise ValueError("Editing tool input has no file targets.")
            regions, notes = inspections(hook_input, capture_context(hook_input))
            result.errors.extend(notes)
            for region in regions:
                code_rules = applicable_rules(
                    rules_path, region.path.parent, additional
                )
                records.extend(rule.record() for rule in code_rules)
                records.append(project_instructions(region.path))
                checked = await evaluate(
                    api,
                    [
                        rule
                        for rule in code_rules
                        if rule.applies("code", request.client, region.path)
                    ],
                    {
                        **state,
                        "path": str(region.path),
                        "input_kind": region.kind,
                        "code": region.code,
                    },
                    cwd,
                    deadline,
                    context_path=region.path,
                    regex_text=region.matching_text(),
                    intent_halted=result.halted,
                    require_complete_input=True,
                )
                result.results.extend(checked.results)
                result.errors.extend(checked.errors)
                result.halted = result.halted or checked.halted
        except (OSError, TypeError, ValueError) as error:
            result.errors.append(f"Cannot inspect proposed changes: {error}")

    digest = hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()
    return {"fingerprint": digest, "results": result.results, "errors": result.errors}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Evaluate one agent tool call without session side effects."
    )
    parser.add_argument("--rules", required=True, type=Path)
    arguments = parser.parse_args()

    async def run() -> dict[str, object]:
        request = Request.model_validate_json(sys.stdin.buffer.read(1024 * 1024 + 1))
        async with httpx.AsyncClient() as api:
            return await check(request, arguments.rules, api)

    try:
        response = asyncio.run(run())
    except (OSError, TypeError, ValueError, TimeoutError) as error:
        response = {"fingerprint": "unavailable", "results": [], "errors": [str(error)]}
    print(json.dumps(response, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
