import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def transmit(data: bytes, layers: int) -> None:
    if not data:
        return

    with open("/dev/tty", "wb") as terminal:
        if layers < 2:
            terminal.write(data)
            return

        # Tupimage already wraps each graphics command once for tmux.
        # Preserve those packet boundaries when adding the outer wrapper.
        # https://github.com/sergei-grechanik/tupimage/blob/7190b180ef904abcdd32882b1f1a93c2e5ffd54a/tupimage#L1380
        packets = re.compile(rb"\x1bPtmux;(?:[^\x1b]|\x1b\x1b)*\x1b\\")
        position = 0
        while position < len(data):
            packet = packets.match(data, position)
            if packet is None:
                raise ValueError("Unexpected tupimage graphics command")
            command = packet.group()
            terminal.write(
                b"\x1bPtmux;" + command.replace(b"\x1b", b"\x1b\x1b") + b"\x1b\\"
            )
            position = packet.end()


def main() -> int:
    try:
        layers = int(os.environ["VIM_IMAGES_TMUX_LAYERS"])
        if layers not in (0, 1, 2) or bool(os.environ.get("TMUX")) != (layers > 0):
            raise ValueError("Use depth 0 outside tmux, or depth 1 or 2 inside tmux")

        # Forward Vim's tupimage arguments without introducing another CLI.
        with tempfile.NamedTemporaryFile(prefix="vim-image-commands-") as commands:
            result = subprocess.run(
                [
                    "bash",
                    sys.argv[1],
                    "--command-tty",
                    commands.name,
                    "--one-way",
                    "--quiet",
                    "--keep-echo",
                    "--no-tmux-hijack",
                    "--uploading-method",
                    "direct",
                    "--force-upload",
                    *sys.argv[2:],
                ],
                check=False,
            )
            if result.returncode != 0:
                return (
                    result.returncode
                    if result.returncode > 0
                    else 128 - result.returncode
                )

            data = Path(commands.name).read_bytes()
            if not data and "--only-dump-dims" not in sys.argv[2:]:
                raise ValueError("Tupimage did not produce an image upload")
            transmit(data, layers)
    except (KeyError, OSError, ValueError) as error:
        print(f"vim-image-upload: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
