import json
import os
import sys
import tomllib
from pathlib import Path
from typing import Any


def render(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True)


def assert_equal(label: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(
            f"{label}\nexpected:\n{render(expected)}\nactual:\n{render(actual)}"
        )


def contains(actual: Any, expected: Any) -> bool:
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            key in actual and contains(actual[key], value)
            for key, value in expected.items()
        )
    if isinstance(expected, list):
        return isinstance(actual, list) and all(
            any(contains(item, expected_item) for item in actual)
            for expected_item in expected
        )
    return actual == expected


def check_value(label: str, actual: Any, expected: dict[str, Any]) -> None:
    if "equals" in expected:
        assert_equal(label, actual, expected["equals"])
    if "contains" in expected and not contains(actual, expected["contains"]):
        raise AssertionError(
            f"{label}\nexpected to contain:\n{render(expected['contains'])}"
            f"\nactual:\n{render(actual)}"
        )
    if "keys" in expected:
        assert_equal(f"{label} keys", sorted(actual), expected["keys"])
    for key, child in expected.get("at", {}).items():
        if not isinstance(actual, dict) or key not in actual:
            raise AssertionError(f"{label} has no {key!r} value")
        check_value(f"{label}.{key}", actual[key], child)


def resolve_path(value: str | dict[str, str]) -> Path:
    if isinstance(value, str):
        return Path(value)
    return Path(os.environ[value["environment"]])


def check_file(destination: str, actual_path: Path, expected: dict[str, Any]) -> None:
    if "sameAs" in expected:
        reference = Path(expected["sameAs"])
        if actual_path.read_bytes() != reference.read_bytes():
            raise AssertionError(f"{destination} differs from {reference}")
        return

    if "text" in expected:
        check_value(
            destination,
            actual_path.read_text(encoding="utf-8"),
            {"equals": expected["text"]},
        )
        return

    if "json" in expected:
        with actual_path.open(encoding="utf-8") as file:
            check_value(destination, json.load(file), expected["json"])
        return

    if "toml" in expected:
        with actual_path.open("rb") as file:
            check_value(destination, tomllib.load(file), expected["toml"])
        return

    raise AssertionError(f"{destination} has no content expectation")


def check_manifest(path: Path) -> None:
    with path.open(encoding="utf-8") as file:
        manifest = json.load(file)

    actual = manifest["actual"]
    expected = manifest["expected"]
    assert_equal(
        f"{manifest['name']} generated files",
        actual["generatedFiles"],
        expected["generatedFiles"],
    )
    assert_equal(
        f"{manifest['name']} checked file names",
        sorted(actual["files"]),
        sorted(expected["files"]),
    )

    for destination, expectation in expected["files"].items():
        check_file(
            destination,
            resolve_path(actual["files"][destination]),
            expectation,
        )
        print(f"PASS: {manifest['name']}: {destination}")


def main() -> int:
    try:
        for argument in sys.argv[1:]:
            check_manifest(Path(argument))
    except (AssertionError, KeyError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
