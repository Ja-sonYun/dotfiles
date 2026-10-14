import json
import shlex
import subprocess
import sys


def main() -> int:
    picker, session, result_option = sys.argv[1:]
    pane_format = (
        "#{session_name}\x1f#{window_id}\x1f#{pane_id}\x1f"
        "#{window_index}.#{pane_index}\x1f#{@agent_display_name}\x1f"
        "#{@agent_name}\x1f#{@agent_conversation}"
    )
    output = subprocess.check_output(
        [
            "tmux",
            "list-panes",
            "-s",
            "-t",
            session,
            "-f",
            "#{==:#{@agent_enabled},1}",
            "-F",
            pane_format,
        ],
        text=True,
    )
    rows: list[str] = []
    targets: dict[str, tuple[str, str, str]] = {}
    for line in output.splitlines():
        session_name, window, pane, index, display_name, agent_name, raw = line.split(
            "\x1f",
            6,
        )
        try:
            conversation: object = json.loads(raw or "{}")
        except json.JSONDecodeError:
            conversation = {}
        title = conversation.get("title") if isinstance(conversation, dict) else None
        title = " ".join(title.split()) if isinstance(title, str) else ""
        name = " ".join((display_name or agent_name or "agent").split())
        label = f"{title} · {name}" if title else name
        target = f"{session}:{window}.{pane}"
        rows.append(f"{target}\t{label} [{index}]")
        targets[target] = (session_name, window, pane)

    if not rows:
        return 0
    selection = subprocess.run(
        [picker, "--stdin"],
        input="\n".join(rows) + "\n",
        stdout=subprocess.PIPE,
        text=True,
        check=False,
    )
    if selection.returncode:
        return selection.returncode
    target = selection.stdout.strip()
    if not target:
        return 0
    if target not in targets:
        print("Agent picker returned an unknown pane.", file=sys.stderr)
        return 1

    session_name, window, pane = targets[target]
    commands = [
        f"select-window -t {shlex.quote(f'{session}:{window}')}",
        f"select-pane -t {shlex.quote(target)}",
    ]
    if session_name == "_popup_all_agents":
        commands.append(f"set-option -s @agent_overview_last {window}.{pane}")
    action = (
        f"if-shell -F -t {shlex.quote(target)} '#{{==:#{{@agent_enabled}},1}}' "
        "{ " + "; ".join(commands) + " }"
    )
    subprocess.run(
        ["tmux", "set-option", "-s", result_option, action],
        check=True,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from error
