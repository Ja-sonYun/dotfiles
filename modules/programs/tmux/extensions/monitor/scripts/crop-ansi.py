import re
import sys

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
    width = int(sys.argv[1])
    for line in sys.stdin:
        sys.stdout.write(crop(line, width))


if __name__ == "__main__":
    main()
