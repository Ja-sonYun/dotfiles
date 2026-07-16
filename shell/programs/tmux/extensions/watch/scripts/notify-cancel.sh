#!/bin/bash
NOTIFY_DIR="/tmp/tmux-notify"
TMUX_BIN="${TMUX_BIN:-tmux}"

case "${1:-}" in
	"")
		orphans_only=0
		;;
	--orphans-only)
		orphans_only=1
		;;
	*)
		exit 2
		;;
esac

if [ "$orphans_only" -eq 0 ]; then
	IFS=$'\x1f' read -r current_pane current_socket < <(
		"$TMUX_BIN" display-message -p $'#{pane_id}\x1f#{socket_path}'
	)
fi

cancelled=0
for info_file in "$NOTIFY_DIR"/*.info; do
	[ -f "$info_file" ] || continue
	pane=$(sed -n 's/^pane=//p' "$info_file" 2>/dev/null)
	socket=$(sed -n 's/^socket=//p' "$info_file" 2>/dev/null)
	remove=0

	if [ "$orphans_only" -eq 0 ] && [ "$pane" = "$current_pane" ] && [ "$socket" = "$current_socket" ]; then
		remove=1
	elif [ -z "$pane" ] || [ -z "$socket" ]; then
		remove=1
	elif ! "$TMUX_BIN" -S "$socket" display-message -t "$pane" -p '#{pane_id}' >/dev/null 2>&1; then
		remove=1
	fi

	if [ "$remove" -eq 1 ] && rm "$info_file" 2>/dev/null; then
		cancelled=$((cancelled + 1))
	fi
done

if [ "$orphans_only" -eq 0 ]; then
	if [ "$cancelled" -gt 0 ]; then
		"$TMUX_BIN" display-message "Notify cancelled ($cancelled)"
	else
		"$TMUX_BIN" display-message "No active notify for this pane"
	fi
fi
