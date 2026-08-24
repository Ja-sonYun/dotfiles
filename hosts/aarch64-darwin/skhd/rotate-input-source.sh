state_dir="${TMPDIR:-/tmp}/skhd"
state_file="$state_dir/input-source-rotation"
now="$(date +%s%3N)"

if [ -r "$state_file" ]; then
	read -r previous_at second_source < "$state_file"
	elapsed=$((now - previous_at))
	if [ "$elapsed" -ge 0 ] && [ "$elapsed" -le 500 ]; then
		rm -f "$state_file"
		exec select-input-source "$second_source"
	fi
	rm -f "$state_file"
fi

current_source="$(macism)"
case "$current_source" in
	com.apple.keylayout.ABC)
		first_source="com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
		second_source="com.apple.inputmethod.Korean.2SetKorean"
		;;
	com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese)
		first_source="com.apple.keylayout.ABC"
		second_source="com.apple.inputmethod.Korean.2SetKorean"
		;;
	com.apple.inputmethod.Korean.2SetKorean)
		first_source="com.apple.keylayout.ABC"
		second_source="com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
		;;
	*)
		first_source="com.apple.keylayout.ABC"
		second_source="com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
		;;
esac

mkdir -p "$state_dir"
printf '%s %s\n' "$now" "$second_source" > "$state_file"
exec select-input-source "$first_source"
