#!/bin/bash
NOTIFY_DIR="/tmp/tmux-notify"
TMUX_BIN="${TMUX_BIN:-tmux}"
mkdir -p "$NOTIFY_DIR"

IFS=$'\x1f' read -r PANE_ID PANE_PID PROCESS_NAME SOCKET_PATH < <(
	"$TMUX_BIN" display-message -p $'#{pane_id}\x1f#{pane_pid}\x1f#{pane_current_command}\x1f#{socket_path}'
)
PANE_PGID=$(/bin/ps -p "$PANE_PID" -o pgid= 2>/dev/null | tr -d ' ')
PROCESS_GROUP=$(/bin/ps -p "$PANE_PID" -o tpgid= 2>/dev/null | tr -d ' ')

if [ -z "$PANE_PGID" ] || [ -z "$PROCESS_GROUP" ] || [ "$PROCESS_GROUP" -le 0 ] || [ "$PROCESS_GROUP" = "$PANE_PGID" ]; then
	"$TMUX_BIN" display-message "No foreground process found"
	exit 0
fi

if ! /bin/kill -0 -- "-$PROCESS_GROUP" 2>/dev/null; then
	"$TMUX_BIN" display-message "No foreground process found"
	exit 0
fi

INFO_FILE="$NOTIFY_DIR/$PROCESS_GROUP.info"

if [ -f "$INFO_FILE" ]; then
	"$TMUX_BIN" display-message "Already watching process group $PROCESS_GROUP"
	exit 0
fi

printf 'pane=%s\nsocket=%s\n' "$PANE_ID" "$SOCKET_PATH" >"$INFO_FILE"

(
	trap 'rm -f "$INFO_FILE"; exit 0' HUP INT TERM

	START_TIME=$(date +%s)

	while [ -f "$INFO_FILE" ] && /bin/kill -0 -- "-$PROCESS_GROUP" 2>/dev/null; do
		sleep 1 &
		wait $!
	done

	[ -f "$INFO_FILE" ] || exit 0
	rm "$INFO_FILE" 2>/dev/null || exit 0

	END_TIME=$(date +%s)
	ELAPSED=$((END_TIME - START_TIME))

	notification_message="$PROCESS_NAME completed (${ELAPSED}s)"
	osascript - "$notification_message" <<'APPLESCRIPT'
on run argv
	display notification (item 1 of argv) with title "tmux notify"
end run
APPLESCRIPT
	afplay /System/Library/Sounds/Glass.aiff &
) &

"$TMUX_BIN" display-message "👁 Watching process group $PROCESS_GROUP ($PROCESS_NAME)"
