#!/bin/bash
# shellcheck source=/dev/null
source "${BASH_SOURCE[0]%/*}/runtime.sh" || exit 1
TMUX_BIN="${TMUX_BIN:-tmux}"
NOTIFY_CLIENT="${2:-}"
notify_init || exit 1

case "${1:-}" in
	%[0-9]*)
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
		"$TMUX_BIN" display-message -pt "$1" $'#{pane_id}\x1f#{socket_path}'
	)
	[[ "$current_pane" == "$1" ]] || exit 0
fi

cancelled=0
notify_lock || exit 1
for info_file in "$NOTIFY_DIR"/*.info; do
	[ -f "$info_file" ] || continue
	pane=$(sed -n 's/^pane=//p' "$info_file" 2>/dev/null)
	socket=$(sed -n 's/^socket=//p' "$info_file" 2>/dev/null)
	remove=0

	if [ "$orphans_only" -eq 0 ] && [ "$pane" = "$current_pane" ] && [ "$socket" = "$current_socket" ]; then
		remove=1
	elif [ -z "$pane" ] || [ -z "$socket" ]; then
		remove=1
	elif ! notify_watcher_alive "$info_file"; then
		remove=1
	elif ! "$TMUX_BIN" -S "$socket" display-message -t "$pane" -p '#{pane_id}' >/dev/null 2>&1; then
		remove=1
	fi

	if [ "$remove" -eq 1 ] && rm "$info_file" 2>/dev/null; then
		cancelled=$((cancelled + 1))
	fi
done
notify_unlock

if [ "$orphans_only" -eq 0 ]; then
	if [ "$cancelled" -gt 0 ]; then
		notify_message "$NOTIFY_CLIENT" "Notify cancelled ($cancelled)"
	else
		notify_message "$NOTIFY_CLIENT" "No active notify for this pane"
	fi
fi
