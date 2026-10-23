import json
import os
import socket
from datetime import UTC, datetime

_connection: socket.socket | None = None
_owner = 0
_path = ""


def log_event(
    component: str,
    level: str,
    event: str,
    **fields: str | int | None,
) -> None:
    global _connection, _owner, _path

    path = os.environ.get("TMUX_LOG_SOCKET")
    if not path:
        return
    context = {
        "pane_id": os.environ.get("TMUX_PANE", ""),
        "client": os.environ.get("AI_AGENT_CLIENT", ""),
        "session_id": os.environ.get("AI_AGENT_SESSION_ID", ""),
        **fields,
    }
    packet = (
        json.dumps(
            {
                "time": datetime.now(UTC).isoformat(),
                "component": component,
                "level": level,
                "event": event,
                "pid": os.getpid(),
                "fields": {key: str(value) for key, value in context.items()},
            },
            separators=(",", ":"),
        )
        + "\n"
    ).encode()
    if len(packet) > 32768:
        return

    if _connection is not None and (_owner != os.getpid() or _path != path):
        _connection.close()
        _connection = None
    try:
        if _connection is None:
            _connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            _connection.setblocking(False)
            if hasattr(socket, "SO_NOSIGPIPE"):
                _connection.setsockopt(socket.SOL_SOCKET, socket.SO_NOSIGPIPE, 1)
            _connection.connect(path)
            _owner = os.getpid()
            _path = path
        if _connection.send(packet, getattr(socket, "MSG_NOSIGNAL", 0)) != len(packet):
            _connection.close()
            _connection = None
    except OSError:
        # Drop without retrying; a partial frame must not precede another event.
        if _connection is not None:
            _connection.close()
            _connection = None
