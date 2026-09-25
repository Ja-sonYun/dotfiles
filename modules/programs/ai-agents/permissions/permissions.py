import argparse
import json
import sys
from copy import deepcopy
from pathlib import Path
from typing import Literal, NotRequired, TypedDict

type Json = None | bool | int | float | str | list[Json] | dict[str, Json]
Decision = Literal["allow", "ask", "deny"]
Access = Literal["allow", "deny"]


class CommandRule(TypedDict):
    prefix: list[str]
    decision: Decision


class Commands(TypedDict):
    rules: list[CommandRule]


class FileRule(TypedDict):
    path: str
    read: Access
    write: Access


class Files(TypedDict):
    rules: list[FileRule]


class Server(TypedDict):
    default: Decision | None
    tools: dict[str, Decision]


class PresetRules(TypedDict, total=False):
    files: list[FileRule]
    allow: list[str]
    deny: list[str]
    network: dict[str, Json]


class Preset(TypedDict):
    name: str
    default: bool
    description: str
    files: NotRequired[list[FileRule]]
    claude: NotRequired[PresetRules]
    codex: NotRequired[PresetRules]


class ExpandedPresets(TypedDict):
    files: list[FileRule]
    allow: list[str]
    deny: list[str]
    network: dict[str, Json]


class UnixSockets(TypedDict):
    allow: list[str]


class Policy(TypedDict):
    presets: list[Preset]
    unixSockets: UnixSockets
    webSearch: Access | None
    commands: Commands
    files: Files
    mcp: dict[str, Server]


def table(parent: dict[str, Json], key: str) -> dict[str, Json]:
    value = parent.setdefault(key, {})
    if not isinstance(value, dict):
        raise TypeError(f"Expected a settings object at {key!r}.")
    return value


def strings(parent: dict[str, Json], key: str) -> list[str]:
    value = parent.get(key, [])
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise TypeError(f"Expected a string list at {key!r}.")
    return [item for item in value if isinstance(item, str)]


def file_access(rule: FileRule) -> str:
    if rule["read"] == "deny":
        if rule["write"] != "deny":
            raise ValueError(f"Cannot allow writing without reading {rule['path']!r}.")
        return "deny"
    return "write" if rule["write"] == "allow" else "read"


def expand_presets(
    presets: list[Preset], client: Literal["claude", "codex"]
) -> ExpandedPresets:
    """Collect selected rules, rejecting conflicting network defaults."""
    result: ExpandedPresets = {"files": [], "allow": [], "deny": [], "network": {}}
    for preset in presets:
        native = (
            preset.get("claude", {}) if client == "claude" else preset.get("codex", {})
        )
        result["files"].extend(preset.get("files", []))
        result["files"].extend(native.get("files", []))
        result["allow"].extend(native.get("allow", []))
        result["deny"].extend(native.get("deny", []))
        for key, value in native.get("network", {}).items():
            if key in result["network"] and result["network"][key] != value:
                raise ValueError(
                    f"Conflicting network default {key!r} in preset {preset['name']!r}."
                )
            result["network"][key] = deepcopy(value)
    return result


def claude_settings(
    settings: dict[str, Json], policy: Policy, plugin: str
) -> dict[str, Json]:
    """Prepend generated permissions so native deny-list exceptions follow them.

    Raise ValueError if a shared MCP tool would relax its server's ask or deny.
    """
    permissions = table(settings, "permissions")
    expanded = expand_presets(policy["presets"], "claude")
    rules: dict[str, list[str]] = {
        "allow": expanded["allow"],
        "ask": [],
        "deny": [],
    }
    if policy["webSearch"] is not None:
        rules[policy["webSearch"]].append("WebSearch")
    for rule in policy["commands"]["rules"]:
        prefix = " ".join(rule["prefix"])
        rules[rule["decision"]].extend([f"Bash({prefix})", f"Bash({prefix} *)"])

    for rule in expanded["files"] + policy["files"]["rules"]:
        file_access(rule)
        path = rule["path"]
        if path.startswith("/"):
            path = "/" + path
        elif not path.startswith("~/"):
            path = "./" + path.removeprefix("./")
        rules[rule["read"]].append(f"Read({path})")
        rules[rule["write"]].append(f"Edit({path})")

    rules["deny"].extend(expanded["deny"])

    priority = {"allow": 0, "ask": 1, "deny": 2}
    for server, entry in policy["mcp"].items():
        default = entry["default"]
        if default is not None and any(
            priority[value] < priority[default] for value in entry["tools"].values()
        ):
            raise ValueError(
                f"Claude cannot override the {default!r} MCP default for {server!r}. "
                "Define this policy in the client's native settings."
            )
        for prefix in (f"mcp__{server}__", f"mcp__plugin_{plugin}_{server}__"):
            if default is not None:
                rules[default].append(prefix + "*")
            for tool, value in entry["tools"].items():
                rules[value].append(prefix + tool)

    for value, entries in rules.items():
        permissions[value] = list[Json](entries + strings(permissions, value))
    if policy["unixSockets"]["allow"]:
        network = table(table(settings, "sandbox"), "network")
        network["allowUnixSockets"] = list(
            dict.fromkeys(
                strings(network, "allowUnixSockets") + policy["unixSockets"]["allow"]
            )
        )
    return settings


def codex_settings(settings: dict[str, Json], policy: Policy) -> dict[str, Json]:
    """Merge native file, socket, search and selected-server permissions.

    Existing tool restrictions and stricter access at the same file path are kept.
    File rules, presets and sockets require the managed profile or raise ValueError.
    """
    if policy["webSearch"] == "deny":
        settings["web_search"] = "disabled"
    elif policy["webSearch"] == "allow":
        settings.setdefault("web_search", "live")

    expanded = expand_presets(policy["presets"], "codex")
    rules = expanded["files"]
    rules.extend(
        {"path": path, "read": "allow", "write": "allow"}
        for path in policy["unixSockets"]["allow"]
    )
    rules.extend(policy["files"]["rules"])
    if rules or expanded["network"]:
        if settings.get("default_permissions") != "managed":
            raise ValueError(
                "Shared file permissions and defaults require Codex's managed profile."
            )
        managed = table(table(settings, "permissions"), "managed")
        if expanded["network"]:
            network = table(managed, "network")
            for key, value in expanded["network"].items():
                network.setdefault(key, value)
        filesystem = table(managed, "filesystem")
        priority = {"write": 0, "read": 1, "deny": 2}
        for rule in rules:
            access = file_access(rule)
            path = rule["path"]
            target = filesystem
            if not path.startswith(("/", "~/")):
                target = table(filesystem, ":workspace_roots")
                path = path.removeprefix("./")
            path = path.removesuffix("/**")
            previous = target.get(path)
            if previous is not None:
                if not isinstance(previous, str) or previous not in priority:
                    raise ValueError(
                        f"Cannot merge the Codex filesystem entry {path!r}."
                    )
                access = max((access, previous), key=priority.__getitem__)
            target[path] = access

        if policy["unixSockets"]["allow"]:
            sockets = table(table(managed, "network"), "unix_sockets")
            for path in policy["unixSockets"]["allow"]:
                sockets.setdefault(path, "allow")

    servers = table(settings, "mcp_servers")
    for server, entry in policy["mcp"].items():
        if server not in servers:
            continue
        native = table(servers, server)
        native_default = native.get("default_tools_approval_mode")
        default = entry["default"]
        if default == "deny":
            permitted = {
                tool for tool, value in entry["tools"].items() if value != "deny"
            }
            if "enabled_tools" in native:
                permitted.intersection_update(strings(native, "enabled_tools"))
            native["enabled_tools"] = list[Json](sorted(permitted))
            if not permitted:
                native["enabled"] = False
        elif default == "ask":
            native["default_tools_approval_mode"] = "prompt"
            for tool, options in table(native, "tools").items():
                if tool not in entry["tools"]:
                    if not isinstance(options, dict):
                        raise TypeError(
                            f"Expected MCP tool settings for {server}.{tool}."
                        )
                    options["approval_mode"] = "prompt"
        elif default == "allow":
            native.setdefault("default_tools_approval_mode", "approve")

        disabled = set(strings(native, "disabled_tools"))
        for tool, value in entry["tools"].items():
            options = table(table(native, "tools"), tool)
            if value == "deny":
                options["enabled"] = False
                disabled.add(tool)
            elif value == "ask":
                options["approval_mode"] = "prompt"
            else:
                options.setdefault(
                    "approval_mode",
                    native_default if native_default is not None else "approve",
                )
        if disabled:
            native["disabled_tools"] = list[Json](sorted(disabled))
    return settings


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert shared permissions to native client settings."
    )
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--client", choices=("claude", "codex"), required=True)
    parser.add_argument("--claude-plugin", default="hm")
    parser.add_argument(
        "--rules",
        action="store_true",
        help="Output Codex command rules instead of settings.",
    )
    args = parser.parse_args()

    try:
        with args.config.open(encoding="utf-8") as stream:
            policy: Policy = json.load(stream)
        if args.rules:
            if args.client != "codex":
                raise ValueError("--rules is only supported for Codex.")
            decisions = {"allow": "allow", "ask": "prompt", "deny": "forbidden"}
            for rule in policy["commands"]["rules"]:
                print(
                    f"prefix_rule(pattern = {json.dumps(rule['prefix'])}, "
                    f"decision = {json.dumps(decisions[rule['decision']])})"
                )
            return 0

        settings: Json = json.load(sys.stdin)
        if not isinstance(settings, dict):
            raise TypeError("Expected a JSON settings object on stdin.")
        if args.client == "claude":
            result = claude_settings(settings, policy, args.claude_plugin)
        else:
            result = codex_settings(settings, policy)
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Cannot convert shared permissions: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
