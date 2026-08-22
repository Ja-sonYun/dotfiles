lock_dir="${TMPDIR:-/tmp}/yabai-reconcile-spaces-$UID"
if ! mkdir "$lock_dir" 2>/dev/null; then
	exit 0
fi
trap 'rmdir "$lock_dir"' EXIT

/bin/sleep 2

current_spaces=$(yabai -m query --spaces)
displays=$(jq -r '[.[] | select(."is-native-fullscreen" == false) | .display] | unique[]' <<<"$current_spaces")

while read -r display; do
	if [[ -z "$display" ]]; then
		continue
	fi

	desktop_count=$(jq --argjson display "$display" '
    [.[] | select(.display == $display and ."is-native-fullscreen" == false)] | length
  ' <<<"$current_spaces")

	missing=$((target_desktops - desktop_count))
	spaces_created=0
	while ((missing > 0)); do
		if yabai -m space --create "$display"; then
			missing=$((missing - 1))
			spaces_created=1
			/bin/sleep 0.2
		else
			echo "yabai-reconcile-spaces: display $display is missing $missing desktop(s); creation failed" >&2
			break
		fi
	done
	if ((spaces_created)); then
		current_spaces=$(yabai -m query --spaces)
	fi

	desktop_count=$(jq --argjson display "$display" '
    [.[] | select(.display == $display and ."is-native-fullscreen" == false)] | length
  ' <<<"$current_spaces")
	excess=$((desktop_count - target_desktops))
	if ((excess <= 0)); then
		continue
	fi

	candidates=$(jq -r --argjson display "$display" '
    [
      .[]
      | select(.display == $display)
      | select(."is-native-fullscreen" == false)
      | select(."is-visible" == false)
      | select((.windows | length) == 0)
    ]
    | sort_by(.index)
    | reverse[]
    | .index
  ' <<<"$current_spaces")

	spaces_destroyed=0
	while read -r index; do
		if ((excess == 0)); then
			break
		fi
		if [[ -z "$index" ]]; then
			continue
		fi

		current_spaces=$(yabai -m query --spaces)
		jq -e --argjson index "$index" --argjson display "$display" '
      any(.[];
        .index == $index
        and .display == $display
        and ."is-native-fullscreen" == false
        and ."is-visible" == false
        and (.windows | length) == 0
      )
    ' <<<"$current_spaces" >/dev/null || continue

		desktop_count=$(jq --argjson display "$display" '
      [.[] | select(.display == $display and ."is-native-fullscreen" == false)] | length
    ' <<<"$current_spaces")
		if ((desktop_count <= target_desktops)); then
			excess=0
			break
		fi

		if yabai -m space --destroy "$index"; then
			excess=$((excess - 1))
			spaces_destroyed=1
			/bin/sleep 0.2
		fi
	done <<<"$candidates"
	if ((spaces_destroyed)); then
		current_spaces=$(yabai -m query --spaces)
	fi

	if ((excess > 0)); then
		echo "yabai-reconcile-spaces: display $display kept $excess excess desktop(s); none were safely removable" >&2
	fi
done <<<"$displays"

visible_spaces=$(yabai -m query --spaces | jq -r '
  .[]
  | select(.type == "bsp")
  | select(."is-visible" == true)
  | select(."is-native-fullscreen" == false)
  | .index
')

while read -r index; do
	if [[ -z "$index" ]]; then
		continue
	fi

	yabai -m space "$index" --padding "$padding_spec" --gap "$gap_spec"
done <<<"$visible_spaces"
