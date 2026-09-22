# shellcheck shell=bash
state_dir="${TMPDIR:-/tmp}/skhd"
state_file="$state_dir/input-source-rotation"
umask 077
mkdir -p "$state_dir"
if [ "${1:-}" != --locked ]; then
	now="$(date +%s%3N)"
	exec /usr/bin/lockf -k "$state_dir/input-source-rotation.lock" "$0" --locked "$now" "$@"
fi
now="$2"
shift 2

select_source() {
	select-input-source "$1" || return
	for _ in $(seq 1 50); do
		if [ "$(macism)" = "$1" ]; then
			return 0
		fi
		sleep 0.02
	done
	printf 'Input source did not change to %s\n' "$1" >&2
	return 1
}

if [ -r "$state_file" ]; then
	read -r previous_at second_source <"$state_file"
	elapsed=$((now - previous_at))
	if [ "$elapsed" -ge 0 ] && [ "$elapsed" -le 500 ]; then
		rm -f "$state_file"
		select_source "$second_source"
		exit $?
	fi
	rm -f "$state_file"
fi

current_source="$(macism)"
sources=()
for source in "$@"; do
	if [ "$source" != "$current_source" ]; then
		sources+=("$source")
	fi
done
if [ "${#sources[@]}" -lt 2 ]; then
	printf 'Rotation requires two alternatives to the current input source.\n' >&2
	exit 2
fi
first_source="${sources[0]}"
second_source="${sources[1]}"

select_source "$first_source"
printf '%s %s\n' "$now" "$second_source" >"$state_file"
