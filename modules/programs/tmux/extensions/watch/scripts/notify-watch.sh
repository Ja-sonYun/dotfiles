#!/bin/bash

# shellcheck source=/dev/null
source "${BASH_SOURCE[0]%/*}/runtime.sh" || exit 1
TMUX_BIN="${TMUX_BIN:-tmux}"

IFS=$'\x1f' read -r PANE_ID PANE_PID PROCESS_NAME SOCKET_PATH SERVER_PID < <(
	"$TMUX_BIN" display-message -p $'#{pane_id}\x1f#{pane_pid}\x1f#{pane_current_command}\x1f#{socket_path}\x1f#{pid}'
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

[[ "$SERVER_PID" =~ ^[0-9]+$ && "$PANE_ID" =~ ^%[0-9]+$ ]] || exit 1
INFO_FILE="$NOTIFY_DIR/$SERVER_PID-${PANE_ID#%}-$PROCESS_GROUP.info"
WATCHER_START=$(/bin/ps -p "$$" -o lstart=) || exit 1
GROUP_START=$(/bin/ps -p "$PROCESS_GROUP" -o lstart= 2>/dev/null)

notify_lock || exit 1
if [ -f "$INFO_FILE" ] && notify_watcher_alive "$INFO_FILE"; then
	"$TMUX_BIN" display-message "Already watching process group $PROCESS_GROUP"
	notify_unlock
	exit 0
fi
printf 'pane=%s\nsocket=%s\nwatcher=%s\nwatcher_start=%s\n' \
	"$PANE_ID" "$SOCKET_PATH" "$$" "$WATCHER_START" >"$INFO_FILE" || exit 1
notify_unlock

owns_record() {
	[ -f "$INFO_FILE" ] &&
	[ "$(sed -n 's/^watcher=//p' "$INFO_FILE")" = "$$" ] &&
	[ "$(sed -n 's/^watcher_start=//p' "$INFO_FILE")" = "$WATCHER_START" ]
}

cleanup_notify() {
	notify_lock || return
	if owns_record; then
		rm -f "$INFO_FILE"
	fi
	notify_unlock
}

trap cleanup_notify EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

START_TIME=$(date +%s)
"$TMUX_BIN" display-message "Watching process group $PROCESS_GROUP ($PROCESS_NAME)"
while owns_record && /bin/kill -0 -- "-$PROCESS_GROUP" 2>/dev/null; do
	CURRENT_GROUP_START=$(/bin/ps -p "$PROCESS_GROUP" -o lstart= 2>/dev/null)
	if [ -n "$GROUP_START" ] && [ -n "$CURRENT_GROUP_START" ] && [ "$CURRENT_GROUP_START" != "$GROUP_START" ]; then
		break
	fi
	sleep 1
done

notify_lock || exit 1
if ! owns_record; then
	notify_unlock
	exit 0
fi
rm -f "$INFO_FILE"
notify_unlock

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
notification_message="$PROCESS_NAME completed (${ELAPSED}s)"
osascript - "$notification_message" <<'APPLESCRIPT'
on run argv
	display notification (item 1 of argv) with title "tmux notify"
end run
APPLESCRIPT
afplay /System/Library/Sounds/Glass.aiff &
