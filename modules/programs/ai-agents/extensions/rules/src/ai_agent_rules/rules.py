import json
import re
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Annotated, Literal, Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    model_validator,
)

from ai_agent_rules.rule_files import (
    project_root,
    read_rules,
    rule_path,
    rules_directory,
)
from ai_agent_rules.sessions import require_session, state_lock

NonEmptyText = Annotated[str, StringConstraints(min_length=1, pattern=r"\S")]
Extension = Annotated[
    str, StringConstraints(to_lower=True, pattern=r"^\.[A-Za-z0-9]+$")
]
Target = Literal["code", "tool", "task"]


class Trigger(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    pattern: NonEmptyText | None = None
    matcher: NonEmptyText | None = None
    inputFields: list[NonEmptyText] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_patterns(self) -> Self:
        for pattern in (self.pattern, self.matcher):
            if pattern is not None:
                try:
                    re.compile(pattern)
                except re.error as error:
                    raise ValueError(f"Invalid regular expression: {error}") from error
        return self


class Check(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    intent: NonEmptyText | None = None
    regex: NonEmptyText | None = None

    @model_validator(mode="after")
    def validate_kind(self) -> Self:
        if (self.intent is None) == (self.regex is None):
            raise ValueError("Specify exactly one of check.intent and check.regex.")
        if self.regex is not None:
            try:
                re.compile(self.regex)
            except re.error as error:
                raise ValueError(f"Invalid regular expression: {error}") from error
        return self


class RuleDefinition(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    enable: bool = True
    target: Target
    title: NonEmptyText | None = None
    extensions: list[Extension] = Field(default_factory=list)
    trigger: Trigger = Field(default_factory=Trigger)
    check: Check
    why: NonEmptyText
    message: NonEmptyText

    @model_validator(mode="after")
    def validate_extensions(self) -> Self:
        if self.extensions and self.target != "code":
            raise ValueError("Only code rules may specify extensions.")
        if self.target != "tool" and (
            self.trigger.matcher is not None or self.trigger.inputFields
        ):
            raise ValueError("Only tool rules may select tool names or input fields.")
        return self


@dataclass(frozen=True)
class Rule:
    id: str
    definition: RuleDefinition
    source: str
    path: Path | None = None
    effective: bool = True

    def applies(self, target: Target, path: Path | None = None) -> bool:
        if (
            not self.effective
            or not self.definition.enable
            or self.definition.target != target
        ):
            return False

        return target != "code" or (
            path is not None
            and (
                not self.definition.extensions
                or path.suffix.lower() in self.definition.extensions
            )
        )

    def record(self) -> dict[str, object]:
        return {
            **self.definition.model_dump(mode="json"),
            "id": self.id,
            "title": self.definition.title or self.id,
            "source": self.source,
            "path": str(self.path) if self.path is not None else None,
            "effective": self.effective,
        }


def parse_rules(data: object, source: str, directory: Path | None = None) -> list[Rule]:
    if not isinstance(data, dict):
        raise TypeError("Rules must be a JSON object.")
    rules = []
    for name, value in sorted(data.items()):
        if not isinstance(name, str) or not name.strip():
            raise ValueError("Rule ID must not be empty.")
        try:
            definition = RuleDefinition.model_validate(value)
        except ValueError as error:
            raise ValueError(f"Invalid {source} rule: {name}") from error
        rules.append(
            Rule(
                name,
                definition,
                source,
                rule_path(directory, name) if directory is not None else None,
            )
        )
    return rules


def load_rules(path: Path) -> list[Rule]:
    return parse_rules(json.loads(path.read_text(encoding="utf-8")), "static")


def effective_rules(
    path: Path, handle: str | None, cwd: Path | None = None
) -> tuple[Path, list[Rule]]:
    static = load_rules(path)
    fallback: Path | None = None
    with state_lock() as metadata:
        if handle is not None:
            session = require_session(metadata, handle)
            cwd = cwd if cwd is not None else session.cwd
            fallback = session.cwd
        elif cwd is None:
            raise ValueError("A working directory is required without a session.")
        directory = rules_directory(project_root(cwd, fallback))
        project = parse_rules(read_rules(directory), "project", directory)

    static_ids = {rule.id for rule in static}
    project = [replace(rule, effective=rule.id not in static_ids) for rule in project]
    return cwd, [*static, *project]
