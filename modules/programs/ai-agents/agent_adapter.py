import argparse
import json
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


AGENT_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
MODEL_CLIENTS = ("claude", "codex", "pi")
MODEL_TIERS = ("xhigh", "high", "middle", "low")
CODEX_PREAMBLE = (
    "Treat references to CLAUDE.md as references to the nearest applicable "
    "AGENTS.md.\n"
    "Use Codex subagent collaboration when the instructions mention Claude's "
    "Task tool.\n\n"
)


@dataclass(frozen=True)
class ModelConfig:
    model: str
    reasoning_effort: str | None = None


ModelMap = dict[str, dict[str, ModelConfig]]


@dataclass(frozen=True)
class ParsedTool:
    server: str


@dataclass(frozen=True)
class Agent:
    source: Path
    frontmatter: dict[str, Any]
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
    parser.add_argument("--claude-plugin", required=True)
    return parser.parse_args()


def read_model_map(path: Path) -> ModelMap:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != set(MODEL_CLIENTS):
        raise ValueError(f"Invalid model map clients in {path}")

    model_map: ModelMap = {}
    for client in MODEL_CLIENTS:
        models = data[client]
        if not isinstance(models, dict) or set(models) != set(MODEL_TIERS):
            raise ValueError(f"Invalid {client} model tiers in {path}")
        model_map[client] = {}
        for tier, value in models.items():
            if not isinstance(value, dict):
                raise ValueError(f"Invalid {client} {tier} model config in {path}")
            model = value.get("model")
            effort = value.get("reasoning_effort")
            if not isinstance(model, str) or not model:
                raise ValueError(f"Invalid {client} {tier} model in {path}")
            if effort is not None and (not isinstance(effort, str) or not effort):
                raise ValueError(f"Invalid {client} {tier} reasoning effort in {path}")
            model_map[client][tier] = ModelConfig(model, effort)
    return model_map


def read_mcp_servers(
    path: Path,
) -> tuple[tuple[str, ...], dict[str, dict[str, Any]]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    servers = data.get("servers")
    codex_servers = data.get("codex_servers")
    if not isinstance(servers, list) or not all(
        isinstance(server, str) for server in servers
    ):
        raise ValueError(f"Invalid MCP server manifest: {path}")
    if not isinstance(codex_servers, dict) or not all(
        isinstance(name, str) and isinstance(config, dict)
        for name, config in codex_servers.items()
    ):
        raise ValueError(f"Invalid Codex MCP server manifest: {path}")
    return tuple(sorted(servers, key=len, reverse=True)), codex_servers


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
        raise ValueError(f"Invalid frontmatter in {path}")
    return data, "".join(lines[end + 1 :])


def string_field(data: dict[str, Any], field: str, path: Path) -> str | None:
    value = data.get(field)
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string in {path}")
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
    claude_plugin: str,
) -> ParsedTool | None:
    for server in servers:
        prefixes = (
            f"mcp__plugin_{claude_plugin}_{server}__",
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
    claude_plugin: str,
) -> tuple[ParsedTool, ...] | None:
    if names is None:
        return None

    tools: list[ParsedTool] = []
    for name in names:
        if not name.startswith("mcp__"):
            raise ValueError(f"Only MCP server wildcards are supported: {name}")
        tool = parse_mcp_tool(name, servers, claude_plugin)
        if tool is None:
            raise ValueError(f"Unknown MCP tool namespace: {name}")
        tools.append(tool)
    return tuple(tools)


def read_agent(
    path: Path,
    servers: tuple[str, ...],
    claude_plugin: str,
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
        raise ValueError(
            f"Unsupported permissionMode {permission_mode!r} in {path}"
        )

    model = string_field(data, "model", path)
    if model not in (None, "inherit", *MODEL_TIERS):
        raise ValueError(f"Unsupported model {model!r} in {path}")

    return Agent(
        source=path,
        frontmatter=data,
        name=name,
        description=description,
        body=body,
        model=model,
        permission_mode=permission_mode,
        tools=parse_tools(tool_names(data, path), servers, claude_plugin),
    )


def resolve_model(
    agent: Agent,
    client: str,
    model_map: ModelMap,
) -> ModelConfig | None:
    if agent.model in (None, "inherit"):
        return None
    return model_map[client][agent.model]


def render_claude(
    agent: Agent,
    model_map: ModelMap,
    output_dir: Path,
) -> None:
    path = output_dir / "claude" / agent.source.name
    if agent.model in (None, "inherit"):
        shutil.copyfile(agent.source, path)
        return

    frontmatter = dict(agent.frontmatter)
    if (model := resolve_model(agent, "claude", model_map)) is not None:
        frontmatter["model"] = model.model
        if model.reasoning_effort is not None:
            frontmatter["effort"] = model.reasoning_effort
    rendered = yaml.safe_dump(
        frontmatter,
        allow_unicode=True,
        sort_keys=False,
    )
    path.write_text(
        f"---\n{rendered}---\n{agent.body}",
        encoding="utf-8",
    )


def codex_sandbox_mode(agent: Agent) -> str | None:
    if agent.permission_mode == "plan":
        return "read-only"
    return None


def codex_mcp_servers(
    agent: Agent,
    servers: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]] | None:
    if agent.tools is None:
        return None

    allowed_servers = {tool.server for tool in agent.tools}
    settings: dict[str, dict[str, Any]] = {}
    for name, config in servers.items():
        if name not in allowed_servers:
            settings[name] = config | {"enabled": False}
    return settings


def render_codex(
    agent: Agent,
    servers: dict[str, dict[str, Any]],
    model_map: ModelMap,
    output_dir: Path,
) -> dict[str, object]:
    config: dict[str, object] = {
        "name": agent.name,
        "description": agent.description,
        "developer_instructions": CODEX_PREAMBLE + agent.body.lstrip("\n"),
    }
    if (model := resolve_model(agent, "codex", model_map)) is not None:
        config["model"] = model.model
        if model.reasoning_effort is not None:
            config["model_reasoning_effort"] = model.reasoning_effort
    if (sandbox_mode := codex_sandbox_mode(agent)) is not None:
        config["sandbox_mode"] = sandbox_mode
    if (mcp_servers := codex_mcp_servers(agent, servers)) is not None:
        config["mcp_servers"] = mcp_servers

    path = output_dir / "codex" / f"{agent.name}.json"
    path.write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return {
        "description": agent.description,
        "config_file": str(path.with_suffix(".toml")),
    }


def pi_proxy_name(server: str) -> str:
    return f"mcp__{server.replace('-', '_')}"


def pi_tools(agent: Agent) -> list[str] | None:
    if agent.tools is None:
        return None

    names: list[str] = []
    for tool in agent.tools:
        names.append(pi_proxy_name(tool.server))
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
    if (model := resolve_model(agent, "pi", model_map)) is not None:
        frontmatter["model"] = (
            f"{model.model}:{model.reasoning_effort}"
            if model.reasoning_effort is not None
            else model.model
        )
    if (tools := pi_tools(agent)) is not None:
        frontmatter["tools"] = tools
    rendered = yaml.safe_dump(
        frontmatter,
        allow_unicode=True,
        sort_keys=False,
    )
    (output_dir / "pi" / agent.source.name).write_text(
        f"---\n{rendered}---\n{agent.body}",
        encoding="utf-8",
    )


def validate_pi_server_names(servers: tuple[str, ...]) -> None:
    names: dict[str, str] = {}
    for server in servers:
        name = pi_proxy_name(server)
        if existing := names.get(name):
            raise ValueError(
                f"MCP servers {existing!r} and {server!r} collide as Pi tool {name!r}"
            )
        names[name] = server


def write_outputs(
    source_dir: Path,
    output_dir: Path,
    model_map: ModelMap,
    servers: tuple[str, ...],
    codex_servers: dict[str, dict[str, Any]],
    claude_plugin: str,
) -> None:
    validate_pi_server_names(servers)
    for directory in ("claude", "codex", "pi"):
        (output_dir / directory).mkdir(parents=True, exist_ok=True)

    registry: dict[str, dict[str, dict[str, object]]] = {"agents": {}}
    for path in sorted(source_dir.glob("*.md")):
        if path.name == "README.md":
            continue
        agent = read_agent(path, servers, claude_plugin)
        render_claude(agent, model_map, output_dir)
        registry["agents"][agent.name] = render_codex(
            agent,
            codex_servers,
            model_map,
            output_dir,
        )
        render_pi(agent, model_map, output_dir)

    (output_dir / "codex" / "agents.json").write_text(
        json.dumps(registry, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    args = parse_arguments()
    model_map = read_model_map(args.model_map)
    servers, codex_servers = read_mcp_servers(args.mcp_servers)
    write_outputs(
        args.source_dir,
        args.output_dir,
        model_map,
        servers,
        codex_servers,
        args.claude_plugin,
    )


if __name__ == "__main__":
    main()
