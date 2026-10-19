import json
import re
import tomllib
from pathlib import Path
from typing import Annotated, Literal, Self

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

from pi_rules.rules import NonEmptyText, RuleDefinition

Decision = Literal["allow", "ask", "deny"]
Name = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_.-]+$")]
Token = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_./:@%+=,-]+$")]


class ConfigurationModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class CommandRule(ConfigurationModel):
    prefix: Annotated[list[Token], Field(min_length=1)]
    decision: Decision


class CommandPolicy(ConfigurationModel):
    rules: list[CommandRule] = Field(default_factory=list)


class FileRule(ConfigurationModel):
    path: NonEmptyText
    read: Literal["allow", "deny"]
    write: Literal["allow", "deny"]

    @model_validator(mode="after")
    def validate_access(self) -> Self:
        if self.read == "deny" and self.write != "deny":
            raise ValueError(
                "File permissions cannot allow writing while denying reading."
            )
        return self


class FilePolicy(ConfigurationModel):
    rules: list[FileRule] = Field(default_factory=list)


class ServerPolicy(ConfigurationModel):
    default: Decision | None = None
    tools: dict[Name, Decision] = Field(default_factory=dict)


class Policy(ConfigurationModel):
    presets: dict[str, bool] = Field(default_factory=dict)
    commands: CommandPolicy = Field(default_factory=CommandPolicy)
    files: FilePolicy = Field(default_factory=FilePolicy)
    mcp: dict[Name, ServerPolicy] = Field(default_factory=dict)
    mcp_readonly_tools: dict[Name, list[Name]] = Field(default_factory=dict)


class Preset(ConfigurationModel):
    name: str
    default: bool
    description: str
    files: list[FileRule] = Field(default_factory=list)


class RuleFiles(ConfigurationModel):
    code: NonEmptyText | None = None
    tool: NonEmptyText | None = None
    task: NonEmptyText | None = None


class Summaries(ConfigurationModel):
    provider: NonEmptyText
    model: NonEmptyText


class Configuration(ConfigurationModel):
    policy: Policy = Field(default_factory=Policy)
    rules: RuleFiles = Field(default_factory=RuleFiles)
    summaries: Summaries | None = None


class ConfigRequest(ConfigurationModel):
    path: str | None
    configDir: str


def load_configuration(request: ConfigRequest) -> dict[str, object]:
    sources: dict[str, str] = {}

    def read_toml(path: Path) -> dict[str, object]:
        key = str(path.resolve())
        if key not in sources:
            sources[key] = path.read_text(encoding="utf-8")
        return tomllib.loads(sources[key])

    path = Path(request.path).absolute() if request.path is not None else None
    config = Configuration.model_validate(read_toml(path) if path is not None else {})
    directory = Path(request.configDir)
    catalog = json.loads(
        (directory / "permissions" / "presets.json").read_text(encoding="utf-8")
    )
    presets = [Preset.model_validate(value) for value in catalog]
    names = {preset.name for preset in presets}
    if len(names) != len(presets):
        raise ValueError("Permission preset names must be unique.")
    if config.policy.presets.keys() - names:
        raise ValueError("Unknown permission preset.")
    selected = {preset.name: preset.default for preset in presets}
    selected.update(config.policy.presets)
    policy = config.policy.model_dump(mode="json", exclude={"presets"})
    policy["defaultRead"] = selected["defaults"]
    policy["files"] = {
        "rules": [
            rule.model_dump(mode="json")
            for rule in [
                *config.policy.files.rules,
                *(
                    rule
                    for preset in presets
                    if selected[preset.name]
                    for rule in preset.files
                ),
            ]
        ]
    }

    rules: dict[str, object] = {}
    for target, reference in (
        ("code", config.rules.code),
        ("tool", config.rules.tool),
        ("task", config.rules.task),
    ):
        if reference is None:
            continue
        if path is None:
            raise ValueError("Rule files require a permissions configuration path.")
        definitions = read_toml(path.parent / reference)
        for name, value in definitions.items():
            if re.fullmatch(r"[A-Za-z0-9_-]+", name) is None:
                raise ValueError(
                    "Rule IDs require letters, digits, underscores or hyphens."
                )
            if name in rules:
                raise ValueError("Rule IDs must be unique across rule groups.")
            if not isinstance(value, dict):
                raise TypeError("Rule definitions must be TOML tables.")
            if "target" in value:
                raise ValueError("The rule group determines its target.")
            definition = RuleDefinition.model_validate({**value, "target": target})
            rules[name] = definition.model_dump(mode="json") | {
                "title": definition.title or name
            }

    defaults = json.loads((directory / "defaults.json").read_text(encoding="utf-8"))
    summaries = config.summaries
    if "summaries" not in config.model_fields_set:
        summaries = Summaries.model_validate(defaults["summaries"])
    return {
        "source": json.dumps(sources) if path is not None else None,
        "config": {
            "policy": policy,
            "configuredRules": rules,
            "summaries": summaries.model_dump(mode="json") if summaries else None,
            "parser": "shfmt",
            "search": "rg",
            "evaluator": ["pi-permissions-evaluator", "check"],
        },
    }
