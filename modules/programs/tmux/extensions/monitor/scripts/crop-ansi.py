import re
import subprocess
import sys
import time

from wcwidth import wcswidth

TOKEN = re.compile(r"\x1b\[[0-9;:]*m|.")


def crop(line: str, width: int) -> str:
    visible = ""
    output: list[str] = []
    for match in TOKEN.finditer(line):
        token = match.group()
        if token.startswith("\x1b["):
            output.append(token)
            continue

        columns = wcswidth(visible + token)
        if columns < 0:
            continue
        if columns > width:
            break
        visible += token
        output.append(token)
    return "".join(output) + "\x1b[0m\n"


def main() -> None:
    if sys.argv[1] == "--view":
        view(*sys.argv[2:])
        return
    width = int(sys.argv[1])
    for line in sys.stdin:
        sys.stdout.write(crop(line, width))


def view(tmux: str, pane: str, source: str) -> None:
    last: tuple[str, int, int] | None = None
    visible = True
    while True:
        args = [
            tmux,
            "display-message",
            "-pt",
            pane,
            "#{window_id} #{pane_width} #{pane_height}",
        ]
        if visible:
            args.extend(
                [";", "display-message", "-pt", source, "#{pane_id} #{cursor_y}"]
            )
        args.extend([";", "list-clients", "-F", "#{window_id}"])
        try:
            snapshot = subprocess.run(
                args,
                check=True,
                capture_output=True,
                text=True,
                timeout=2,
            ).stdout.splitlines()
            window, width_text, height_text = snapshot[0].split()
            width, height = int(width_text), int(height_text)
            clients = snapshot[2:] if visible else snapshot[1:]
            if window not in clients:
                visible = False
                time.sleep(1)
                continue
            if not visible:
                visible = True
                continue
            current, cursor_text = snapshot[1].split()
            if current != source:
                return
            cursor = int(cursor_text)
            content = subprocess.run(
                [
                    tmux,
                    "capture-pane",
                    "-ep",
                    "-t",
                    source,
                    "-S",
                    str(max(0, cursor - height + 1)),
                    "-E",
                    str(cursor),
                ],
                check=True,
                capture_output=True,
                text=True,
                timeout=2,
            ).stdout
        except (OSError, subprocess.SubprocessError, ValueError, IndexError):
            return
        current_content = (content, width, height)
        if current_content != last:
            rendered = "".join(crop(line, width) for line in content.splitlines())
            sys.stdout.write("\x1b[0m\x1b[H\x1b[2J" + rendered.rstrip("\n"))
            sys.stdout.flush()
            last = current_content
        time.sleep(0.5)


if __name__ == "__main__":
    main()
