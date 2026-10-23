import argparse
import json
import os
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
    antigravity: NotRequired[PresetRules]


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
    presets: list[Preset], client: Literal["claude", "codex", "antigravity"]
) -> ExpandedPresets:
    """Collect selected rules, rejecting conflicting network defaults."""
    result: ExpandedPresets = {"files": [], "allow": [], "deny": [], "network": {}}
    for preset in presets:
        if client == "claude":
            native = preset.get("claude", {})
        elif client == "codex":
            native = preset.get("codex", {})
        else:
            native = preset.get("antigravity", {})
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


def antigravity_settings(
    settings: dict[str, Json], policy: Policy, home: Path
) -> dict[str, Json]:
    """Merge native grants and command/MCP rules; the file hook enforces denials.

    Reject file grants and MCP exceptions that native permissions cannot express.
    https://www.antigravity.google/docs/permissions?tab=cli
    """
    permissions = table(settings, "permissions")
    expanded = expand_presets(policy["presets"], "antigravity")
    rules: dict[str, list[str]] = {
        "allow": expanded["allow"],
        "ask": [],
        "deny": expanded["deny"],
    }
    for rule in policy["commands"]["rules"]:
        prefix = " ".join(rule["prefix"])
        rules[rule["decision"]].append(f"command({prefix})")

    priority = {"allow": 0, "ask": 1, "deny": 2}
    for server, entry in policy["mcp"].items():
        default = entry["default"]
        if default is not None and any(
            priority[value] < priority[default] for value in entry["tools"].values()
        ):
            raise ValueError(
                f"Antigravity cannot override the {default!r} MCP default for {server!r}."
            )
        if default is not None:
            rules[default].append(f"mcp({server}/*)")
        for tool, value in entry["tools"].items():
            rules[value].append(f"mcp({server}/{tool})")

    for rule in expanded["files"] + policy["files"]["rules"]:
        if file_access(rule) == "deny":
            continue
        path = rule["path"].removesuffix("/**") or "/"
        if path == "~":
            path = str(home)
        elif path.startswith("~/"):
            path = str(home / path.removeprefix("~/"))
        if any(character in path for character in "*?[()\n\r\0"):
            raise ValueError(
                f"Antigravity cannot represent the file grant {rule['path']!r}; "
                "use a literal path or a trailing /**."
            )
        rules["allow"].append(f"read_file({path})")
        if rule["write"] == "allow":
            rules["allow"].append(f"write_file({path})")

    for value, entries in rules.items():
        permissions[value] = list[Json](
            dict.fromkeys(entries + strings(permissions, value))
        )
    return settings


def antigravity_path_matches(
    path: Path, pattern: str, cwd: Path, *, resolve_pattern: bool = True
) -> bool:
    absolute = cwd / Path(pattern).expanduser()
    if resolve_pattern:
        prefix = Path(absolute.anchor)
        suffix = list(absolute.parts[1:])
        while suffix and not any(character in suffix[0] for character in "*?["):
            prefix /= suffix.pop(0)
        resolved = prefix.resolve().joinpath(*suffix)
    else:
        # An allowed symlink name must not exempt its protected destination.
        resolved = absolute.parent.resolve() / absolute.name
    patterns = {str(absolute), str(resolved)}
    if pattern.endswith("/**"):
        patterns.update(value.removesuffix("/**") or "/" for value in tuple(patterns))
    return any(
        candidate.full_match(value, case_sensitive=sys.platform != "darwin")
        for candidate in (path, *path.parents)
        for value in patterns
    )


def antigravity_check_path(
    path: Path, access: Literal["read", "write"], policy: Policy, cwd: Path
) -> None:
    # Apply each preset independently to both the supplied path and its destination.
    for candidate in {Path(os.path.abspath(path)), path.resolve()}:
        if any(
            rule[access] == "deny"
            and antigravity_path_matches(candidate, rule["path"], cwd)
            for rule in policy["files"]["rules"]
        ):
            raise PermissionError(
                f"Shared file permissions deny {access} access to {path}."
            )

        for preset in policy["presets"]:
            # Exceptions belong to this preset, never to user or other preset denials.
            exceptions = [
                rule
                for rule in preset.get("antigravity", {}).get("files", [])
                if antigravity_path_matches(
                    candidate, rule["path"], cwd, resolve_pattern=False
                )
            ]
            rules = exceptions or [
                rule
                for rule in preset.get("files", [])
                if antigravity_path_matches(candidate, rule["path"], cwd)
            ]
            if any(rule[access] == "deny" for rule in rules):
                raise PermissionError(
                    f"Shared file permissions deny {access} access to {path}."
                )


def antigravity_file_hook(hook_input: dict[str, object], policy: Policy) -> None:
    """Reject restricted file tools without granting native approval to other calls."""
    from ai_agent_hooks.edit_input import edit_targets

    if hook_input.get("hook_event_name") != "PreToolUse":
        raise ValueError("File permissions require a PreToolUse event.")
    tool = hook_input.get("tool_name")
    if not isinstance(tool, str) or not tool:
        raise ValueError("Missing tool name in the file permission request.")
    read_fields = {
        "Read": "file_path",
        "view_file": "AbsolutePath",
        "view_file_outline": "AbsolutePath",
        "view_code_item": "File",
    }
    search_tools = {"grep_search", "find_by_name", "list_dir", "codebase_search"}
    native_edits = {
        "write_to_file",
        "replace_file_content",
        "multi_replace_file_content",
    }
    editing = tool in {"Write", "Edit", "MultiEdit"}
    if tool not in read_fields and tool not in search_tools and not editing:
        if tool in native_edits:
            raise ValueError("The native file edit could not be normalized.")
        return

    tool_input = hook_input.get("tool_input")
    cwd_value = hook_input.get("cwd")
    if not isinstance(tool_input, dict):
        raise TypeError("Missing file tool arguments.")
    if not isinstance(cwd_value, str) or not Path(cwd_value).is_absolute():
        raise ValueError("Missing absolute workspace path for file permissions.")
    cwd = Path(cwd_value)

    access: Literal["read", "write"] = "write" if editing else "read"
    if editing:
        paths = [
            path
            for target in edit_targets(hook_input, resolve_paths=False)
            for path in (target.before, target.after)
        ]
        if not paths:
            raise ValueError("Cannot determine the files modified by this tool.")
    elif tool in search_tools:
        restricted = any(
            rule["read"] == "deny"
            for rule in policy["files"]["rules"]
            + expand_presets(policy["presets"], "antigravity")["files"]
        )
        if not restricted:
            return
        value = tool_input.get("SearchPath") if tool == "grep_search" else None
        if not isinstance(value, str) or not value:
            raise PermissionError(
                "Cannot establish the files accessed by this search while shared "
                "file read restrictions are active."
            )
        path = cwd / Path(value).expanduser()
        if not path.is_file():
            raise PermissionError(
                "Directory searches cannot enforce shared file read restrictions."
            )
        paths = [path]
    else:
        value = tool_input.get(read_fields[tool])
        if not isinstance(value, str) or not value:
            raise ValueError("Cannot determine the file read by this tool.")
        paths = [cwd / Path(value).expanduser()]

    for path in dict.fromkeys(paths):
        antigravity_check_path(path, access, policy, cwd)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert shared permissions to native client settings."
    )
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument(
        "--client", choices=("claude", "codex", "antigravity"), required=True
    )
    parser.add_argument("--claude-plugin", default="hm")
    parser.add_argument(
        "--home", type=Path, help="User home for Antigravity file grants."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--rules",
        action="store_true",
        help="Output Codex command rules instead of settings.",
    )
    mode.add_argument(
        "--hook",
        action="store_true",
        help="Enforce Antigravity file permissions for a canonical PreToolUse input.",
    )
    args = parser.parse_args()

    try:
        with args.config.open(encoding="utf-8") as stream:
            policy: Policy = json.load(stream)
        if args.hook:
            if args.client != "antigravity":
                raise ValueError("--hook is only supported for Antigravity.")
            hook_input = json.load(sys.stdin)
            if not isinstance(hook_input, dict):
                raise TypeError("Expected a JSON hook input object.")
            antigravity_file_hook(hook_input, policy)
            return 0
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
        elif args.client == "codex":
            result = codex_settings(settings, policy)
        else:
            if args.home is None or not args.home.is_absolute():
                raise ValueError(
                    "Antigravity settings require an absolute --home path."
                )
            result = antigravity_settings(settings, policy, args.home)
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        if args.hook and args.client == "antigravity":
            from ai_agent_hooks.hook_input import emit_feedback

            emit_feedback(
                "PreToolUse",
                [str(error)],
                deny_reason="Shared Antigravity file permissions denied this tool call.",
            )
            return 0
        print(f"Cannot convert shared permissions: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
