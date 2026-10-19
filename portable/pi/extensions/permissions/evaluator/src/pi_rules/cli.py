import argparse
import asyncio
import hashlib
import json
import os
import sys
import time
from dataclasses import replace
from pathlib import Path
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, Field, model_validator

from pi_rules.checks import evaluate
from pi_rules.code_changes import inspections, project_instructions
from pi_rules.config import ConfigRequest, load_configuration
from pi_rules.edit_context import capture_context
from pi_rules.edit_input import ToolInput, edit_targets, is_edit_tool
from pi_rules.rule_files import project_root, read_rules, rules_directory
from pi_rules.rules import Rule, parse_rules
from pi_rules.transport import Transport


class Request(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    client: Literal["pi"]
    target: Literal["tool", "task"] = "tool"
    cwd: str
    tool_name: str
    tool_input: dict[str, object]
    context: dict[str, object] = Field(default_factory=dict)
    additionalRules: dict[str, object] = Field(default_factory=dict)
    configuredRules: dict[str, object]
    check_summary: bool = False

    @model_validator(mode="after")
    def validate_context(self) -> Self:
        if self.context.keys() & {"client", "cwd", "tool_name", "tool_input"}:
            raise ValueError("Context must not override tool call fields.")
        if self.target == "task" and not isinstance(self.tool_input.get("text"), str):
            raise ValueError("Task checks require text.")
        return self


def applicable_rules(
    static: list[Rule], cwd: Path, additional: list[Rule]
) -> list[Rule]:
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


def snapshot(request: Request) -> dict[str, object]:
    cwd = Path(request.cwd).resolve()
    static = parse_rules(request.configuredRules, "static")
    additional = parse_rules(request.additionalRules, "caller")
    records: list[object] = [
        request.client,
        *(rule.record() for rule in applicable_rules(static, cwd, additional)),
        project_instructions(cwd / "AGENTS.md"),
    ]
    files = {}
    targets = edit_targets(
        {
            "cwd": str(cwd),
            "tool_name": request.tool_name,
            "tool_input": request.tool_input,
        },
        resolve_paths=False,
    )
    for path in sorted(
        {path for target in targets for path in (target.before, target.after)}
    ):
        resolved = path.resolve()
        records.extend(
            rule.record()
            for rule in applicable_rules(static, resolved.parent, additional)
        )
        records.append(project_instructions(resolved))
        try:
            with resolved.open("rb") as source:
                digest = hashlib.file_digest(source, "sha256").hexdigest()
                mode = os.fstat(source.fileno()).st_mode
        except FileNotFoundError:
            digest, mode = None, None
        files[str(path)] = [str(resolved), digest, mode]
    return {
        "fingerprint": hashlib.sha256(
            json.dumps(records, sort_keys=True).encode()
        ).hexdigest(),
        "file_state": hashlib.sha256(
            json.dumps(files, sort_keys=True).encode()
        ).hexdigest(),
    }


async def check(request: Request, api: Transport) -> dict[str, object]:
    cwd = Path(request.cwd).resolve()
    additional = parse_rules(request.additionalRules, "caller")
    static = parse_rules(request.configuredRules, "static")
    rules = applicable_rules(static, cwd, additional)
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
    stamp = await asyncio.to_thread(snapshot, request)
    if request.target == "task":
        text = str(request.tool_input["text"])
        result = await evaluate(
            api,
            [rule for rule in rules if rule.applies("task")],
            {**state, "text": text},
            cwd,
            deadline,
            context_path=cwd / "AGENTS.md",
            regex_text=text,
            require_complete_input=True,
        )
        return {
            **stamp,
            "results": result.results,
            "errors": result.errors,
            "status": "incomplete"
            if result.errors or result.halted
            else ("completed" if result.applicable_rule_count else "skipped"),
        }
    inspection_errors: list[str] = []
    async with asyncio.TaskGroup() as group:
        tool_check = group.create_task(
            evaluate(
                api,
                [rule for rule in rules if rule.applies("tool")],
                dict(state),
                cwd,
                deadline,
                context_path=cwd / "AGENTS.md",
                require_complete_input=True,
                check_summary=request.check_summary,
            )
        )
        code_checks = []
        if is_edit_tool(request.tool_name):
            hook_input: ToolInput = {
                "cwd": str(cwd),
                "tool_name": request.tool_name,
                "tool_input": request.tool_input,
            }
            try:
                if not edit_targets(hook_input):
                    raise ValueError("Editing tool input has no file targets.")
                replacement_context = await asyncio.to_thread(
                    capture_context, hook_input
                )
                regions, notes = await asyncio.to_thread(
                    inspections, hook_input, replacement_context
                )
                inspection_errors.extend(notes)
                for region in regions:
                    code_rules = applicable_rules(
                        static, region.path.parent, additional
                    )
                    code_checks.append(
                        group.create_task(
                            evaluate(
                                api,
                                [
                                    rule
                                    for rule in code_rules
                                    if rule.applies("code", region.path)
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
                                require_complete_input=True,
                            )
                        )
                    )
            except (OSError, TypeError, ValueError) as error:
                inspection_errors.append(f"Cannot inspect proposed changes: {error}")

    result = tool_check.result()
    result.errors.extend(inspection_errors)
    for task in code_checks:
        checked = task.result()
        result.results.extend(checked.results)
        result.errors.extend(checked.errors)
        result.halted = result.halted or checked.halted

    return {
        **stamp,
        "results": result.results,
        "errors": result.errors,
        "needs_summary": result.needs_summary,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Evaluate one Pi tool call without session side effects."
    )
    parser.add_argument("command", choices=("config", "check", "state"))
    arguments = parser.parse_args()

    async def run() -> dict[str, object]:
        request = Request.model_validate_json(
            sys.stdin.buffer.readline(1024 * 1024 + 1)
        )
        if arguments.command == "state":
            return {**snapshot(request), "results": [], "errors": []}
        async with Transport() as api:
            return await check(request, api)

    try:
        if arguments.command == "config":
            response = load_configuration(
                ConfigRequest.model_validate_json(
                    sys.stdin.buffer.readline(1024 * 1024 + 1)
                )
            )
        else:
            response = asyncio.run(run())
    except (OSError, TypeError, ValueError, TimeoutError) as error:
        if arguments.command == "config":
            print(str(error), file=sys.stderr)
            return 1
        response = {"fingerprint": "unavailable", "results": [], "errors": [str(error)]}
    print(json.dumps({"type": "done", "value": response}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
