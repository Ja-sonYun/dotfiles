import json
import os
import sys
import tempfile
from pathlib import Path


def main() -> None:
    token = Path(sys.argv[1]).read_text().strip()
    if not token:
        raise ValueError("Reminders authentication key is empty")
    target = Path(sys.argv[2])
    payload = json.loads(target.read_text()) if target.exists() else {}
    payload.update(
        version=1,
        host="127.0.0.1",
        port=7362,
        token=token,
        allowedHosts=[],
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=target.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(payload, output)
            output.write("\n")
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
