import json
import sys
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text()) if path.exists() else {}


def merge_dicts(
    base: dict[str, Any],
    overlay: dict[str, Any],
) -> dict[str, Any]:
    result = dict(base)
    for k, v in overlay.items():
        result[k] = v
    return result


if __name__ == "__main__":
    claude_json_path = Path(sys.argv[1])  # ~/.claude.json
    managed_path = Path(sys.argv[2])  # nix store file (mcpServers, disabledMcpjsonServers)

    claude_json = load_json(claude_json_path)
    managed = load_json(managed_path)

    claude_json = merge_dicts(claude_json, managed)

    claude_json_path.write_text(json.dumps(claude_json, indent=2))
