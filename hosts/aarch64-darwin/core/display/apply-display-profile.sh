usage() {
  printf 'Usage: %s [--list|--dry-run|--help] [profiles.json]\n' "$0"
}

mode="apply"
case "${1:-}" in
  --help | -h)
    usage
    exit 0
    ;;
  --list)
    mode="list"
    shift
    ;;
  --dry-run)
    mode="dry-run"
    shift
    ;;
  "")
    ;;
  *)
    if [ "${1#-}" != "$1" ]; then
      usage >&2
      exit 2
    fi
    ;;
esac

profile_path="${1:-${APPLY_DISPLAY_PROFILE_CONFIG:-}}"

if command -v displayplacer >/dev/null 2>&1; then
  displayplacer_bin="$(command -v displayplacer)"
elif [ -x /opt/homebrew/bin/displayplacer ]; then
  displayplacer_bin="/opt/homebrew/bin/displayplacer"
elif [ -x /usr/local/bin/displayplacer ]; then
  displayplacer_bin="/usr/local/bin/displayplacer"
else
  printf 'displayplacer is not installed. Run darwin switch to install the Homebrew formula.\n' >&2
  exit 1
fi

display_list="$("$displayplacer_bin" list)"

if [ "$mode" = "list" ]; then
  printf '%s\n' "$display_list"
  exit 0
fi

if [ -z "$profile_path" ]; then
  printf 'No display profile config provided.\n' >&2
  exit 1
fi

if [ ! -f "$profile_path" ]; then
  printf 'Display profile config not found: %s\n' "$profile_path" >&2
  exit 1
fi

profile_tsv="$(mktemp)"
display_list_file="$(mktemp)"
trap 'rm -f "$profile_tsv" "$display_list_file"' EXIT

jq -r '
  .[]
  | [
      .name,
      (.matchType // ""),
      (.matchId // ""),
      (.matchName // ""),
      (.matchSerial // ""),
      (.matchIndex // ""),
      .resolution,
      (.scaling // "on"),
      (.origin // ""),
      (.degree // "")
    ]
    | @tsv
' "$profile_path" > "$profile_tsv"

printf '%s\n' "$display_list" > "$display_list_file"

mapfile -t display_args < <(
  gawk '
    BEGIN {
      FS = "\t"
      reset()
    }

    function reset() {
      id = ""
      serial = ""
      type = ""
      origin = "(0,0)"
      degree = "0"
      current_res = ""
      current_scaling = ""
      mode_count = 0
      delete mode_res
      delete mode_scaling
    }

    function normalize_serial(value) {
      sub(/^s/, "", value)
      return value
    }

    function normalize_name(value) {
      value = tolower(value)
      gsub(/[[:space:]_-]/, "", value)
      return value
    }

    function profile_matches(profile_index, lower_type, normalized_serial) {
      if (profile_match_type[profile_index] != "" && profile_match_type[profile_index] == "built-in" && lower_type !~ /built[ -]?in/) {
        return 0
      }
      if (profile_match_id[profile_index] != "" && id != profile_match_id[profile_index]) {
        return 0
      }
      if (profile_match_name[profile_index] != "" && index(normalize_name(lower_type), normalize_name(profile_match_name[profile_index])) == 0) {
        return 0
      }
      if (profile_match_serial[profile_index] != "" && normalized_serial != normalize_serial(profile_match_serial[profile_index])) {
        return 0
      }
      if (profile_match_index[profile_index] != "" && profile_match_index[profile_index] != profile_seen[profile_index]) {
        return 0
      }
      return 1
    }

    function choose_resolution(profile_index,   i, target_res, target_scaling, best_res, best_area, parts, area) {
      target_res = profile_resolution[profile_index]
      target_scaling = profile_scaling[profile_index]
      resolved_scaling = target_scaling

      if (target_res == "current") {
        resolved_scaling = current_scaling
        return current_res
      }

      if (target_res == "more-space") {
        best_res = ""
        best_area = -1
        for (i = 1; i <= mode_count; i++) {
          if (mode_scaling[i] != target_scaling) {
            continue
          }
          split(mode_res[i], parts, "x")
          area = parts[1] * parts[2]
          if (area > best_area) {
            best_area = area
            best_res = mode_res[i]
          }
        }
        return best_res
      }

      for (i = 1; i <= mode_count; i++) {
        if (target_scaling != "current" && mode_scaling[i] != target_scaling) {
          continue
        }
        if (mode_res[i] == target_res) {
          if (target_scaling == "current") {
            resolved_scaling = mode_scaling[i]
          }
          return mode_res[i]
        }
      }

      return ""
    }

    function emit(   lower_type, normalized_serial, i, target_res, target_origin, target_degree) {
      if (id == "") {
        return
      }

      lower_type = tolower(type)
      normalized_serial = normalize_serial(serial)

      for (i = 1; i <= profile_count; i++) {
        if (!profile_matches_without_index(i, lower_type, normalized_serial)) {
          continue
        }

        profile_seen[i]++

        if (!profile_matches(i, lower_type, normalized_serial)) {
          continue
        }

        target_res = choose_resolution(i)
        if (target_res == "") {
          printf("warning: no matching mode for profile %s on display %s\n", profile_name[i], type) > "/dev/stderr"
          continue
        }

        target_origin = origin
        if (profile_origin[i] != "") {
          target_origin = profile_origin[i]
        }

        target_degree = degree
        if (profile_degree[i] != "") {
          target_degree = profile_degree[i]
        }

        printf("id:%s res:%s enabled:true scaling:%s origin:%s degree:%s\n", id, target_res, resolved_scaling, target_origin, target_degree)
      }
    }

    function profile_matches_without_index(profile_index, lower_type, normalized_serial) {
      if (profile_match_type[profile_index] != "" && profile_match_type[profile_index] == "built-in" && lower_type !~ /built[ -]?in/) {
        return 0
      }
      if (profile_match_id[profile_index] != "" && id != profile_match_id[profile_index]) {
        return 0
      }
      if (profile_match_name[profile_index] != "" && index(normalize_name(lower_type), normalize_name(profile_match_name[profile_index])) == 0) {
        return 0
      }
      if (profile_match_serial[profile_index] != "" && normalized_serial != normalize_serial(profile_match_serial[profile_index])) {
        return 0
      }
      return 1
    }

    FILENAME == ARGV[1] {
      profile_count++
      profile_name[profile_count] = $1
      profile_match_type[profile_count] = $2
      profile_match_id[profile_count] = $3
      profile_match_name[profile_count] = $4
      profile_match_serial[profile_count] = $5
      profile_match_index[profile_count] = $6
      profile_resolution[profile_count] = $7
      profile_scaling[profile_count] = $8
      profile_origin[profile_count] = $9
      profile_degree[profile_count] = $10
      next
    }

    FILENAME == ARGV[2] && FNR == 1 {
      FS = " "
    }

    FILENAME == ARGV[2] {
      if ($0 ~ /^Persistent screen id:/) {
        emit()
        reset()
        id = $0
        sub(/^Persistent screen id:[[:space:]]*/, "", id)
        next
      }

      if ($0 ~ /^Serial screen id:/) {
        serial = $0
        sub(/^Serial screen id:[[:space:]]*/, "", serial)
        next
      }

      if ($0 ~ /^Type:/) {
        sub(/^Type:[[:space:]]*/, "")
        type = $0
        next
      }

      if ($0 ~ /^Origin:/) {
        origin = $0
        sub(/^Origin:[[:space:]]*/, "", origin)
        next
      }

      if ($0 ~ /^Rotation:/) {
        degree = $0
        sub(/^Rotation:[[:space:]]*/, "", degree)
        gsub(/[^0-9]/, "", degree)
        next
      }

      if ($0 ~ /^[[:space:]]*mode[[:space:]][0-9]+:/) {
        if (match($0, /res:([0-9]+)x([0-9]+)/, res_match)) {
          mode_count++
          mode_res[mode_count] = res_match[1] "x" res_match[2]

          if (match($0, /scaling:(on|off)/, scaling_match)) {
            mode_scaling[mode_count] = scaling_match[1]
          } else {
            mode_scaling[mode_count] = "off"
          }

          if ($0 ~ /<-- current mode/) {
            current_res = mode_res[mode_count]
            current_scaling = mode_scaling[mode_count]
          }
        }
        next
      }
    }

    END {
      emit()
    }
  ' "$profile_tsv" "$display_list_file"
)

if [ "${#display_args[@]}" -eq 0 ]; then
  printf 'No matching display modes found.\n' >&2
  exit 1
fi

printf 'displayplacer'
printf ' %q' "${display_args[@]}"
printf '\n'

if [ "$mode" = "dry-run" ]; then
  exit 0
fi

"$displayplacer_bin" "${display_args[@]}"
