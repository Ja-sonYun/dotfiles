#!/bin/bash
# Watch current pane's foreground process and notify on completion

NOTIFY_DIR="/tmp/tmux-notify"
STATUS_FILE="/tmp/tmux-status-messages/00-notify"
mkdir -p "$NOTIFY_DIR" "$(dirname "$STATUS_FILE")"

PANE_ID=$(tmux display-message -p '#{pane_id}')
PANE_PID=$(tmux display-message -p '#{pane_pid}')
CHILD_PID=$(pgrep -P "$PANE_PID" | head -1)

if [ -z "$CHILD_PID" ]; then
	tmux display-message "No foreground process found"
	exit 0
fi

# Unique ID to handle PID reuse
PROC_START=$(ps -p "$CHILD_PID" -o lstart= 2>/dev/null | tr -s ' ' '_')
UNIQUE_ID="${CHILD_PID}_${PROC_START}"

if [ -f "$NOTIFY_DIR/$UNIQUE_ID.info" ]; then
	tmux display-message "Already watching PID $CHILD_PID"
	exit 0
fi

PROCESS_NAME=$(ps -p "$CHILD_PID" -o comm=)

update_status() {
	local count=$(ls "$NOTIFY_DIR"/*.info 2>/dev/null | wc -l | tr -d ' ')
	if [ "$count" -gt 0 ]; then
		echo "👁${count}" >"$STATUS_FILE"
	else
		rm -f "$STATUS_FILE"
	fi
}

# Create .info file first (without watcher PID)
{
	echo "pid=$CHILD_PID"
	echo "name=$PROCESS_NAME"
	echo "pane=$PANE_ID"
	echo "start=$(date +%s)"
} >"$NOTIFY_DIR/$UNIQUE_ID.info"

# Background watcher
(
	trap 'rm -f "$NOTIFY_DIR/$UNIQUE_ID.info"; update_status; exit 0' TERM

	update_status

	START_TIME=$(date +%s)

	while kill -0 "$CHILD_PID" 2>/dev/null; do
		tmux display-message -t "$PANE_ID" -p '#{pane_id}' >/dev/null 2>&1 || break
		sleep 1 &
		wait $!
	done

	END_TIME=$(date +%s)
	ELAPSED=$((END_TIME - START_TIME))

	rm -f "$NOTIFY_DIR/$UNIQUE_ID.info"
	update_status

	osascript -e "display notification \"$PROCESS_NAME completed (${ELAPSED}s)\" with title \"tmux notify\""
	afplay /System/Library/Sounds/Glass.aiff &
) &

# Append watcher PID
echo "watcher=$!" >>"$NOTIFY_DIR/$UNIQUE_ID.info"

tmux display-message "👁 Watching PID $CHILD_PID ($PROCESS_NAME)"
