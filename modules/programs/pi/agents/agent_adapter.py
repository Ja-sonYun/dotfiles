import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

AGENT_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
MODEL_TIERS = ("xhigh", "high", "middle", "low")


@dataclass(frozen=True)
class ModelConfig:
    model: str
    reasoning_effort: str | None = None


ModelMap = dict[str, ModelConfig]


@dataclass(frozen=True)
class ParsedTool:
    server: str


@dataclass(frozen=True)
class Agent:
    source: Path
    name: str
    description: str
    body: str
    model: str | None
    permission_mode: str | None
    tools: tuple[ParsedTool, ...] | None


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--model-map", type=Path, required=True)
    parser.add_argument("--mcp-servers", type=Path, required=True)
    return parser.parse_args()


def read_model_map(path: Path) -> ModelMap:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != set(MODEL_TIERS):
        raise ValueError(f"Invalid Pi model tiers in {path}")

    model_map: ModelMap = {}
    for tier, value in data.items():
        if not isinstance(value, dict):
            raise TypeError(f"Invalid Pi {tier} model config in {path}")
        model = value.get("model")
        effort = value.get("reasoning_effort")
        if not isinstance(model, str) or not model:
            raise ValueError(f"Invalid Pi {tier} model in {path}")
        if effort is not None and (not isinstance(effort, str) or not effort):
            raise ValueError(f"Invalid Pi {tier} reasoning effort in {path}")
        model_map[tier] = ModelConfig(model, effort)
    return model_map


def read_mcp_servers(path: Path) -> tuple[str, ...]:
    servers = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(servers, list) or not all(
        isinstance(server, str) for server in servers
    ):
        raise ValueError(f"Invalid Pi MCP server manifest: {path}")
    return tuple(sorted(servers, key=len, reverse=True))


def split_frontmatter(path: Path) -> tuple[dict[str, Any], str]:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        raise ValueError(f"Missing frontmatter in {path}")

    try:
        end = next(
            index
            for index, line in enumerate(lines[1:], start=1)
            if line.strip() == "---"
        )
    except StopIteration as error:
        raise ValueError(f"Unterminated frontmatter in {path}") from error

    data = yaml.safe_load("".join(lines[1:end]))
    if not isinstance(data, dict):
        raise TypeError(f"Invalid frontmatter in {path}")
    return data, "".join(lines[end + 1 :])


def string_field(data: dict[str, Any], field: str, path: Path) -> str | None:
    value = data.get(field)
    if value is None:
        return None
    if not isinstance(value, str):
        raise TypeError(f"{field} must be a string in {path}")
    return value


def tool_names(data: dict[str, Any], path: Path) -> tuple[str, ...] | None:
    if "tools" not in data:
        return None

    value = data["tools"]
    if isinstance(value, str):
        names = value.split(",")
    elif isinstance(value, list) and all(isinstance(item, str) for item in value):
        names = value
    else:
        raise ValueError(f"tools must be a string or string list in {path}")

    normalized = tuple(dict.fromkeys(name.strip() for name in names if name.strip()))
    if not normalized:
        raise ValueError(f"tools must contain an MCP server wildcard in {path}")
    return normalized


def parse_mcp_tool(
    name: str,
    servers: tuple[str, ...],
) -> ParsedTool | None:
    for server in servers:
        prefixes = (
            f"mcp__plugin_hm_{server}__",
            f"mcp__{server}__",
        )
        for prefix in prefixes:
            if name.startswith(prefix):
                tool = name.removeprefix(prefix)
                if not tool:
                    raise ValueError(f"Missing MCP tool name in {name}")
                if tool != "*":
                    raise ValueError(
                        f"Exact MCP tool allowlists are unsupported: {name}"
                    )
                return ParsedTool(server)
    return None


def parse_tools(
    names: tuple[str, ...] | None,
    servers: tuple[str, ...],
) -> tuple[ParsedTool, ...] | None:
    if names is None:
        return None

    tools: list[ParsedTool] = []
    for name in names:
        if not name.startswith("mcp__"):
            raise ValueError(f"Only MCP server wildcards are supported: {name}")
        tool = parse_mcp_tool(name, servers)
        if tool is None:
            raise ValueError(f"Unknown MCP tool namespace: {name}")
        tools.append(tool)
    return tuple(tools)


def read_agent(
    path: Path,
    servers: tuple[str, ...],
) -> Agent:
    data, body = split_frontmatter(path)
    name = string_field(data, "name", path)
    description = string_field(data, "description", path)
    if name is None or not AGENT_NAME_PATTERN.fullmatch(name):
        raise ValueError(f"Invalid agent name in {path}")
    if path.stem != name:
        raise ValueError(f"Agent filename and name differ in {path}")
    if not description:
        raise ValueError(f"Missing agent description in {path}")

    permission_mode = string_field(data, "permissionMode", path)
    if permission_mode not in (None, "default", "plan"):
        raise ValueError(f"Unsupported permissionMode {permission_mode!r} in {path}")

    model = string_field(data, "model", path)
    if model not in (None, "inherit", *MODEL_TIERS):
        raise ValueError(f"Unsupported model {model!r} in {path}")

    return Agent(
        source=path,
        name=name,
        description=description,
        body=body,
        model=model,
        permission_mode=permission_mode,
        tools=parse_tools(tool_names(data, path), servers),
    )


def resolve_model(
    agent: Agent,
    model_map: ModelMap,
) -> ModelConfig | None:
    if agent.model in (None, "inherit"):
        return None
    return model_map[agent.model]


def pi_namespace(server: str) -> str:
    # Match native Pi MCP tool names before their per-tool length limit.
    # https://github.com/earendil-works/pi/blob/v1.1.0/packages/coding-agent/src/extensions/mcp/tools.ts
    namespace = re.sub(r"[^A-Za-z0-9_]", "_", server)
    return f"mcp__{namespace}"


def pi_tools(agent: Agent) -> list[str] | None:
    if agent.tools is None:
        return None

    # Shared tool declarations restrict MCP servers, not built-in tools.
    names = [
        "read",
        "grep",
        "find",
        "ls",
        "codemode",
        "tool_search",
    ]
    if agent.permission_mode != "plan":
        names.extend(["bash", "edit", "write"])
    for tool in agent.tools:
        names.append(f"{pi_namespace(tool.server)}__*")
    return list(dict.fromkeys(names))


def render_pi(
    agent: Agent,
    model_map: ModelMap,
    output_dir: Path,
) -> None:
    frontmatter: dict[str, object] = {
        "name": agent.name,
        "description": agent.description,
    }
    if (model := resolve_model(agent, model_map)) is not None:
        frontmatter["model"] = (
            f"{model.model}:{model.reasoning_effort}"
            if model.reasoning_effort is not None
            else model.model
        )
    if (tools := pi_tools(agent)) is not None:
        frontmatter["tools"] = tools
    if agent.permission_mode is not None:
        frontmatter["permissionMode"] = agent.permission_mode
    rendered = yaml.safe_dump(
        frontmatter,
        allow_unicode=True,
        sort_keys=False,
    )
    (output_dir / agent.source.name).write_text(
        f"---\n{rendered}---\n{agent.body}",
        encoding="utf-8",
    )


def validate_pi_server_names(servers: tuple[str, ...]) -> None:
    names: dict[str, str] = {}
    for server in servers:
        name = pi_namespace(server)
        if existing := names.get(name):
            raise ValueError(
                f"MCP servers {existing!r} and {server!r} collide as Pi tool {name!r}"
            )
        names[name] = server


def main() -> None:
    args = parse_arguments()
    model_map = read_model_map(args.model_map)
    servers = read_mcp_servers(args.mcp_servers)
    validate_pi_server_names(servers)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    for path in sorted(args.source_dir.glob("*.md")):
        if path.name != "README.md":
            render_pi(read_agent(path, servers), model_map, args.output_dir)


if __name__ == "__main__":
    main()
