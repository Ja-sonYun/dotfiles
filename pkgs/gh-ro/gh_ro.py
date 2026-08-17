#!/usr/bin/env python3
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from graphql import OperationType, parse
from graphql.error import GraphQLError
from graphql.language import FragmentDefinitionNode, OperationDefinitionNode

GH_PATH = "gh"

READ_ONLY_COMMANDS = frozenset(
    {
        ("codespace", "list"),
        ("gist", "list"),
        ("gist", "view"),
        ("issue", "list"),
        ("issue", "status"),
        ("issue", "view"),
        ("label", "list"),
        ("pr", "checks"),
        ("pr", "diff"),
        ("pr", "list"),
        ("pr", "status"),
        ("pr", "view"),
        ("release", "list"),
        ("release", "view"),
        ("repo", "list"),
        ("repo", "view"),
        ("run", "list"),
        ("run", "view"),
        ("run", "watch"),
        ("workflow", "list"),
        ("workflow", "view"),
    }
)
READ_ONLY_ROOT_COMMANDS = frozenset({"search", "status"})
API_VALUE_OPTIONS = frozenset(
    {
        "--cache",
        "--field",
        "--header",
        "--hostname",
        "--input",
        "--jq",
        "--method",
        "--preview",
        "--raw-field",
        "--template",
        "-F",
        "-H",
        "-X",
        "-f",
        "-p",
        "-q",
        "-t",
    }
)
API_FLAG_OPTIONS = frozenset(
    {
        "--include",
        "--paginate",
        "--silent",
        "--slurp",
        "--verbose",
        "-i",
    }
)
API_FIELD_OPTIONS = frozenset({"--field", "--raw-field", "-F", "-f"})
API_TYPED_FIELD_OPTIONS = frozenset({"--field", "-F"})
API_SHORT_VALUE_OPTIONS = frozenset({"-F", "-H", "-X", "-f", "-p", "-q", "-t"})
METHOD_OVERRIDE_HEADERS = frozenset(
    {
        "x-http-method",
        "x-http-method-override",
        "x-method-override",
    }
)


@dataclass(frozen=True)
class FieldValue:
    value: str
    reads_file: bool


@dataclass(frozen=True)
class ApiRequest:
    endpoint: str
    method: str | None
    fields: dict[str, FieldValue]
    has_fields: bool
    input_path: str | None
    headers: tuple[str, ...]


def run_gh(arguments: list[str]) -> int:
    os.execvp(GH_PATH, [GH_PATH, *arguments])
    return 0


def split_long_option(argument: str) -> tuple[str, str] | None:
    option, separator, value = argument.partition("=")
    if separator and option in API_VALUE_OPTIONS:
        return option, value
    return None


def split_short_option(argument: str) -> tuple[str, str] | None:
    if len(argument) > 2 and argument[:2] in API_SHORT_VALUE_OPTIONS:
        return argument[:2], argument[2:]
    return None


def parse_api(arguments: list[str]) -> ApiRequest | None:
    endpoint: str | None = None
    method: str | None = None
    fields: dict[str, FieldValue] = {}
    has_fields = False
    input_path: str | None = None
    headers: list[str] = []
    index = 0

    while index < len(arguments):
        argument = arguments[index]
        option_value = split_long_option(argument) or split_short_option(argument)

        if option_value is not None:
            option, value = option_value
        elif argument in API_VALUE_OPTIONS:
            index += 1
            if index >= len(arguments):
                return None
            option, value = argument, arguments[index]
        elif argument in API_FLAG_OPTIONS:
            index += 1
            continue
        elif argument == "--":
            index += 1
            if index >= len(arguments) or endpoint is not None:
                return None
            endpoint = arguments[index]
            index += 1
            if index != len(arguments):
                return None
            continue
        elif argument.startswith("-"):
            return None
        elif endpoint is None:
            endpoint = argument
            index += 1
            continue
        else:
            return None

        if option in {"--method", "-X"}:
            method = value
        elif option in API_FIELD_OPTIONS:
            has_fields = True
            name, separator, field_value = value.partition("=")
            if name in {"operationName", "query"}:
                if not separator:
                    return None
                fields[name] = FieldValue(
                    field_value,
                    option in API_TYPED_FIELD_OPTIONS,
                )
        elif option == "--input":
            input_path = value
        elif option in {"--header", "-H"}:
            headers.append(value)

        index += 1

    if endpoint is None:
        return None
    return ApiRequest(endpoint, method, fields, has_fields, input_path, tuple(headers))


def resolve_field(field: FieldValue) -> str | None:
    if not field.reads_file or not field.value.startswith("@"):
        return field.value
    path = field.value[1:]
    if not path or path == "-":
        return None
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError:
        return None


def load_graphql_request(request: ApiRequest) -> tuple[str, str | None] | None:
    if request.input_path is not None:
        if request.has_fields or request.input_path == "-":
            return None
        try:
            payload = json.loads(Path(request.input_path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(payload, dict) or not isinstance(payload.get("query"), str):
            return None
        operation_name = payload.get("operationName")
        if operation_name is not None and not isinstance(operation_name, str):
            return None
        return payload["query"], operation_name

    query_field = request.fields.get("query")
    if query_field is None:
        return None
    query = resolve_field(query_field)
    if query is None:
        return None
    operation_name_field = request.fields.get("operationName")
    operation_name = (
        resolve_field(operation_name_field) if operation_name_field else None
    )
    if operation_name_field is not None and operation_name is None:
        return None
    return query, operation_name


def is_read_only_graphql(query: str, operation_name: str | None) -> bool:
    try:
        document = parse(query)
    except GraphQLError:
        return False

    allowed_definitions = (FragmentDefinitionNode, OperationDefinitionNode)
    if any(
        not isinstance(definition, allowed_definitions)
        for definition in document.definitions
    ):
        return False
    operations = [
        definition
        for definition in document.definitions
        if isinstance(definition, OperationDefinitionNode)
    ]
    if not operations or any(
        operation.operation is not OperationType.QUERY for operation in operations
    ):
        return False
    if operation_name is None:
        return len(operations) == 1

    selected = [
        operation
        for operation in operations
        if operation.name is not None and operation.name.value == operation_name
    ]
    return len(selected) == 1


def has_method_override(headers: tuple[str, ...]) -> bool:
    return any(
        header.partition(":")[0].strip().lower() in METHOD_OVERRIDE_HEADERS
        for header in headers
    )


def is_read_only_api(arguments: list[str]) -> bool:
    request = parse_api(arguments)
    if request is None or has_method_override(request.headers):
        return False
    if request.endpoint == "graphql":
        if request.method not in {None, "GET", "POST"}:
            return False
        graphql_request = load_graphql_request(request)
        return graphql_request is not None and is_read_only_graphql(*graphql_request)
    if request.method == "GET":
        return True
    return arguments == ["rate_limit"]


def is_help_or_version(arguments: list[str]) -> bool:
    if not arguments:
        return True
    return (
        arguments == ["--help"]
        or arguments == ["-h"]
        or arguments[0]
        in {
            "--version",
            "help",
            "version",
        }
    )


def is_read_only(arguments: list[str]) -> bool:
    if is_help_or_version(arguments):
        return True
    if arguments[0] == "api":
        return is_read_only_api(arguments[1:])
    if arguments[0] == "auth" and len(arguments) >= 2 and arguments[1] == "status":
        return not any(
            argument in {"-t", "--show-token"}
            or argument.startswith(("-t=", "--show-token="))
            for argument in arguments[2:]
        )
    if arguments[0] in READ_ONLY_ROOT_COMMANDS:
        return True
    return len(arguments) >= 2 and tuple(arguments[:2]) in READ_ONLY_COMMANDS


def main() -> int:
    arguments = sys.argv[1:]
    if is_read_only(arguments):
        return run_gh(arguments)
    print("gh-ro: command is not classified as read-only", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
