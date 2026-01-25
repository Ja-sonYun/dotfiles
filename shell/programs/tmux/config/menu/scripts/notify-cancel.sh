#!/bin/bash
# Cancel notify watch for current pane

NOTIFY_DIR="/tmp/tmux-notify"
STATUS_FILE="/tmp/tmux-status-messages/00-notify"
PANE_ID=$(tmux display-message -p '#{pane_id}')

found=0
for info_file in "$NOTIFY_DIR"/*.info; do
	[ -f "$info_file" ] || continue
	pane=$(grep '^pane=' "$info_file" | cut -d= -f2)
	if [ "$pane" = "$PANE_ID" ]; then
		watcher=$(grep '^watcher=' "$info_file" | cut -d= -f2)
		kill "$watcher" 2>/dev/null
		rm -f "$info_file"
		found=1
	fi
done

# Update status
count=$(ls "$NOTIFY_DIR"/*.info 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -gt 0 ]; then
	echo "👁${count}" >"$STATUS_FILE"
else
	rm -f "$STATUS_FILE"
fi

if [ "$found" -eq 1 ]; then
	tmux display-message "Notify cancelled for this pane"
else
	tmux display-message "No active notify for this pane"
fi
