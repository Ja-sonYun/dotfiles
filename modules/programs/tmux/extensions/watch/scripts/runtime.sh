#!/usr/bin/env bash

NOTIFY_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-notify-$UID"
notify_message() {
	local client="$1"
	shift
	[[ -n "$client" ]] || return 0
	"$TMUX_BIN" display-message -c "$client" "$@"
}

notify_init() {
	umask 077
	[[ ! -L "$NOTIFY_DIR" ]] || return 1
	mkdir -p "$NOTIFY_DIR" || return 1
	[[ ! -L "$NOTIFY_DIR" && -O "$NOTIFY_DIR" ]] || return 1
	chmod 700 "$NOTIFY_DIR"
}

notify_lock() {
	exec 9>"$NOTIFY_DIR/.lock" || return 1
	flock 9
}

notify_unlock() {
	flock -u 9
	exec 9>&-
}

notify_watcher_alive() {
	local watcher started
	watcher=$(sed -n 's/^watcher=//p' "$1")
	started=$(sed -n 's/^watcher_start=//p' "$1")
	[[ "$watcher" =~ ^[0-9]+$ && -n "$started" ]] || return 1
	[[ "$(/bin/ps -p "$watcher" -o lstart= 2>/dev/null)" == "$started" ]]
}
