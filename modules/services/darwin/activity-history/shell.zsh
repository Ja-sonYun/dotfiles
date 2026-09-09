zmodload zsh/datetime
if (( ! ${+_activity_history_session} )); then
	typeset -g _activity_history_session="$$-${EPOCHREALTIME//./}-$RANDOM"
	typeset -gi _activity_history_sequence=0 _activity_history_skip=0
	typeset -gi _activity_history_session_enabled=0
	typeset -g _activity_history_command_id=""
	typeset -g _activity_history_socket="${TMUX:-}"
	_activity_history_socket="${_activity_history_socket%,*}"
	_activity_history_socket="${_activity_history_socket%,*}"
	if [[ -o interactive && -t 0 ]]; then
		_activity_history_session_enabled=1
		@helper@ _shell-session-start \
			--session="$_activity_history_session" --pid="$$" --at="$EPOCHREALTIME" \
			--cwd="$PWD" --tty="${TTY:-}" --socket="$_activity_history_socket" \
			--pane="${TMUX_PANE:-}" >/dev/null 2>&1 &!
	fi
fi

_activity_history_filter() {
	_activity_history_skip=0
	[[ "$1" == ' '* ]] && _activity_history_skip=1
	return 0
}

_activity_history_start() {
	_activity_history_command_id=""
	local skip=$_activity_history_skip
	_activity_history_skip=0
	(( skip )) && return 0
	[[ "$1" == ' '* ]] && return 0
	_activity_history_sequence=$(( _activity_history_sequence + 1 ))
	_activity_history_command_id="$_activity_history_session-$_activity_history_sequence"
	typeset -g _activity_history_started="$EPOCHREALTIME"
	local history_socket="${TMUX:-}"
	history_socket="${history_socket%,*}"
	history_socket="${history_socket%,*}"
	print -rn -- "$1" | @helper@ _shell-start \
		--session="$_activity_history_session" --command-id="$_activity_history_command_id" \
		--started="$_activity_history_started" --cwd="$PWD" --tty="${TTY:-}" \
		--socket="$history_socket" --pane="${TMUX_PANE:-}" >/dev/null 2>&1 &!
	return 0
}

_activity_history_capture_end() {
	local history_exit=$?
	typeset -g _activity_history_exit="$history_exit"
	typeset -g _activity_history_ended="$EPOCHREALTIME"
	return 0
}

_activity_history_finish() {
	[[ -n "$_activity_history_command_id" ]] || return 0
	@helper@ _shell-end \
		--session="$_activity_history_session" --command-id="$_activity_history_command_id" \
		--started="$_activity_history_started" --ended="$_activity_history_ended" \
		--exit-code="$_activity_history_exit" --cwd="$PWD" >/dev/null 2>&1 &!
	_activity_history_command_id=""
	return 0
}

_activity_history_session_end() {
	local history_exit=$?
	(( _activity_history_session_enabled )) || return 0
	@helper@ _shell-session-end \
		--session="$_activity_history_session" --pid="$$" --at="$EPOCHREALTIME" \
		--cwd="$PWD" --tty="${TTY:-}" --socket="$_activity_history_socket" \
		--pane="${TMUX_PANE:-}" --exit-code="$history_exit" \
		--command-id="$_activity_history_command_id" \
		--started="${_activity_history_started:-0}" >/dev/null 2>&1
	_activity_history_command_id=""
	return 0
}
