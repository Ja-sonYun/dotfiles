# shellcheck shell=bash
configuration="$1"
bundle=$(jq -r '.bundle' "$configuration")
marker="$bundle.source"
source_id=com.aimdevlee.inputmethod.Seamtype
temporary_file=""
trap 'if [[ -n "$temporary_file" ]]; then rm -f -- "$temporary_file"; fi' EXIT

stop_seamtype() {
	local user_id status
	user_id=$(/usr/bin/id -u)
	if /usr/bin/pkill -TERM -u "$user_id" -x Seamtype; then
		for _ in {1..30}; do
			if /usr/bin/pgrep -u "$user_id" -x Seamtype >/dev/null; then
				sleep 0.1
			else
				status=$?
				[[ "$status" == 1 ]]
				return
			fi
		done
		echo "Seamtype did not stop; leaving its bundle in place." >&2
		return 1
	else
		status=$?
		[[ "$status" == 1 ]]
	fi
}

if [[ $(jq -r '.enable' "$configuration") == false ]]; then
	macism com.apple.keylayout.ABC
	seamtype-disable-input-source "$source_id"
	stop_seamtype
	if [[ -f "$marker" ]]; then
		/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
			-u "$bundle"
		rm -rf -- "$bundle"
		rm -f -- "$marker"
	fi
	exit 0
fi

directory=$(jq -r '.directory' "$configuration")
source_bundle=$(jq -r '.source' "$configuration")
settings_changed=false
umask 077
mkdir -p -- "$directory" "$(dirname "$bundle")"

merge_settings() {
	local key file input missing
	key="$1"
	file="$directory/$2"
	input="$file"
	missing=false
	if [[ ! -e "$file" ]]; then
		input=/dev/null
		missing=true
	fi

	temporary_file=$(mktemp "$file.XXXXXX")
	jq -e --slurp --arg key "$key" --argjson missing "$missing" --slurpfile policy "$configuration" '
      (if $missing then
        {}
      elif length != 1 or (.[0] | type) != "object" then
        error("Seamtype settings must contain one object")
      else
        .[0]
      end)
      | if $key == "settings" then
        . * $policy[0].settings
      else
        ($policy[0].appDefaults * .)
        | if $policy[0].holdSpace != null then
          .["*"] //= {}
          | with_entries(.value.holdSpace = $policy[0].holdSpace)
        else
          .
        end
      end
    ' "$input" >"$temporary_file"
	if [[ -e "$file" ]]; then
		chmod --reference="$file" "$temporary_file"
	fi

	if [[ -e "$file" ]] && cmp -s -- "$file" "$temporary_file"; then
		rm -f -- "$temporary_file"
	else
		mv -f -- "$temporary_file" "$file"
		settings_changed=true
	fi
	temporary_file=""
}

merge_settings settings settings.json
merge_settings appDefaults apps.json

installed_source=""
if [[ -f "$marker" ]]; then
	installed_source=$(cat -- "$marker")
fi

if [[ "$installed_source" != "$source_bundle" || ! -x "$bundle/Contents/MacOS/Seamtype" ]]; then
	macism com.apple.keylayout.ABC
	stop_seamtype
	mkdir -p -- "$bundle"
	chmod -R u+w -- "$bundle"
	# Keep the bundle directory stable, as required by the upstream pkg installer.
	# https://github.com/aimdevlee/seamtype/blob/v0.1.13/scripts/pkg/postinstall
	rsync -a --delete --checksum --chmod=u+w "$source_bundle/" "$bundle/"
	temporary_file=$(mktemp "$marker.XXXXXX")
	printf '%s\n' "$source_bundle" >"$temporary_file"
	mv -f -- "$temporary_file" "$marker"
	temporary_file=""
elif [[ "$settings_changed" == true ]]; then
	macism com.apple.keylayout.ABC
	stop_seamtype
fi

"$bundle/Contents/MacOS/Seamtype" --register
