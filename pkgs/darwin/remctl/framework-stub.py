import re
import sys
from pathlib import Path


def main() -> None:
    source = Path(sys.argv[1]).read_text()
    classes = sorted(set(re.findall(r"@interface\s+(REM\w+)\s*:", source)))
    # The private framework is supplied by macOS, not the public Apple SDK.
    # https://github.com/viticci/remctl/blob/d9e934bf25c8f30a620f659268faa9acc4f24e04/remctl-private.m
    Path(sys.argv[2]).write_text(
        "--- !tapi-tbd\n"
        "tbd-version: 4\n"
        "targets: [ arm64-macos ]\n"
        "install-name: /System/Library/PrivateFrameworks/ReminderKit.framework/Versions/A/ReminderKit\n"
        "exports:\n"
        "  - targets: [ arm64-macos ]\n"
        f"    objc-classes: [ {', '.join(classes)} ]\n"
        "...\n"
    )


if __name__ == "__main__":
    main()
