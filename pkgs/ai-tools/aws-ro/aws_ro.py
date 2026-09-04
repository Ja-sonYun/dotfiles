#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path
from typing import cast


AWS_PATH = "@AWS_PATH@"
METADATA_PATH = Path("@METADATA_PATH@")

Metadata = dict[str, dict[str, dict[str, str]]]

BLOCKED_OPERATIONS = frozenset(
    {
        ("sts", "assumerole"),
        ("sts", "assumerolewithwebidentity"),
        ("sts", "assumerolewithsaml"),
        ("sts", "getsessiontoken"),
        ("sts", "getfederationtoken"),
        ("sts", "assumeroot"),
        ("iam", "createaccesskey"),
        ("cognito-identity", "getcredentialsforidentity"),
        ("cognito-identity", "getopenidtoken"),
        ("sso", "getrolecredentials"),
    }
)
SAFE_CUSTOM_OPERATIONS = frozenset({("s3", "ls")})
SERVICE_ALIASES = {
    "configservice": "config",
    "s3api": "s3",
}
GLOBAL_FLAGS = frozenset(
    {
        "--debug",
        "--cli-auto-prompt",
        "--no-cli-auto-prompt",
        "--no-cli-pager",
        "--no-paginate",
        "--no-sign-request",
        "--no-verify-ssl",
    }
)
GLOBAL_VALUE_OPTIONS = frozenset(
    {
        "--ca-bundle",
        "--cli-binary-format",
        "--cli-connect-timeout",
        "--cli-error-format",
        "--cli-read-timeout",
        "--color",
        "--endpoint-url",
        "--output",
        "--profile",
        "--query",
        "--region",
    }
)


def normalize(value: str) -> str:
    return "".join(character for character in value.lower() if character.isalnum())


def load_metadata() -> Metadata:
    with METADATA_PATH.open(encoding="utf-8") as metadata_file:
        return cast(Metadata, json.load(metadata_file))


def parse_command(arguments: list[str]) -> tuple[str, str] | None:
    index = 0
    while index < len(arguments) and arguments[index].startswith("-"):
        option, separator, _ = arguments[index].partition("=")
        if option in GLOBAL_FLAGS:
            index += 1
        elif option in GLOBAL_VALUE_OPTIONS:
            index += 1 if separator else 2
        else:
            return None

    if len(arguments) - index < 2:
        return None
    return arguments[index], arguments[index + 1]


def is_read_only(metadata: Metadata, service: str, operation: str) -> bool:
    service = SERVICE_ALIASES.get(service.lower(), service.lower())
    normalized_operation = normalize(operation)

    if (service, normalized_operation) in BLOCKED_OPERATIONS:
        return False
    if (service, normalized_operation) in SAFE_CUSTOM_OPERATIONS:
        return True

    for action, properties in metadata.get(service, {}).items():
        if normalize(action) == normalized_operation:
            return properties.get("type") == "ReadOnly"
    return False


def run_aws(arguments: list[str]) -> int:
    os.execv(AWS_PATH, [AWS_PATH, *arguments])
    return 0


def main(arguments: list[str]) -> int:
    if not arguments or arguments == ["--version"]:
        return run_aws(arguments)
    if arguments[-1] in {"help", "--help"}:
        return run_aws(arguments)

    command = parse_command(arguments)
    if command is not None:
        service, operation = command
        if is_read_only(load_metadata(), service, operation):
            return run_aws(arguments)

    print("aws-ro: command is not classified as read-only", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
