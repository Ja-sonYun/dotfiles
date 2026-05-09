usage() {
  printf 'Usage: %s [--list|--dry-run|--help] [layouts.json]\n' "$0"
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

layout_path="${1:-${APPLY_DISPLAY_PROFILE_CONFIG:-}}"

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

if [ -z "$layout_path" ]; then
  printf 'No display layout config provided.\n' >&2
  exit 1
fi

if [ ! -f "$layout_path" ]; then
  printf 'Display layout config not found: %s\n' "$layout_path" >&2
  exit 1
fi

layout_tsv="$(mktemp)"
display_list_file="$(mktemp)"
trap 'rm -f "$layout_tsv" "$display_list_file"' EXIT

jq -r '
  to_entries[]
  | .key as $layoutIndex
  | .value as $layout
  | ($layout.displays // [])[]
  | [
      ($layoutIndex + 1),
      $layout.name,
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
' "$layout_path" > "$layout_tsv"

printf '%s\n' "$display_list" > "$display_list_file"

mapfile -t display_args < <(
  gawk '
    BEGIN {
      FS = "\t"
      reset_display()
    }

    function reset_display() {
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

    function store_display(   i) {
      if (id == "") {
        return
      }

      display_count++
      display_id[display_count] = id
      display_serial[display_count] = serial
      display_type[display_count] = type
      display_origin[display_count] = origin
      display_degree[display_count] = degree
      display_current_res[display_count] = current_res
      display_current_scaling[display_count] = current_scaling
      display_mode_count[display_count] = mode_count

      for (i = 1; i <= mode_count; i++) {
        display_mode_res[display_count, i] = mode_res[i]
        display_mode_scaling[display_count, i] = mode_scaling[i]
      }
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

    function display_matches_profile(display_index, profile_index,   lower_type, normalized_serial) {
      lower_type = tolower(display_type[display_index])
      normalized_serial = normalize_serial(display_serial[display_index])

      if (profile_match_type[profile_index] != "" && profile_match_type[profile_index] == "built-in" && lower_type !~ /built[ -]?in/) {
        return 0
      }
      if (profile_match_id[profile_index] != "" && display_id[display_index] != profile_match_id[profile_index]) {
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

    function find_display_for_profile(profile_index,   display_index, seen) {
      seen = 0

      for (display_index = 1; display_index <= display_count; display_index++) {
        if (!display_matches_profile(display_index, profile_index)) {
          continue
        }

        seen++
        if (profile_match_index[profile_index] == "" || profile_match_index[profile_index] == seen) {
          return display_index
        }
      }

      return 0
    }

    function choose_resolution(profile_index, display_index,   i, target_res, target_scaling, best_res, best_area, parts, area) {
      target_res = profile_resolution[profile_index]
      target_scaling = profile_scaling[profile_index]
      resolved_scaling = target_scaling

      if (target_res == "current") {
        resolved_scaling = display_current_scaling[display_index]
        return display_current_res[display_index]
      }

      if (target_res == "more-space") {
        best_res = ""
        best_area = -1
        for (i = 1; i <= display_mode_count[display_index]; i++) {
          if (display_mode_scaling[display_index, i] != target_scaling) {
            continue
          }
          split(display_mode_res[display_index, i], parts, "x")
          area = parts[1] * parts[2]
          if (area > best_area) {
            best_area = area
            best_res = display_mode_res[display_index, i]
          }
        }
        return best_res
      }

      for (i = 1; i <= display_mode_count[display_index]; i++) {
        if (target_scaling != "current" && display_mode_scaling[display_index, i] != target_scaling) {
          continue
        }
        if (display_mode_res[display_index, i] == target_res) {
          if (target_scaling == "current") {
            resolved_scaling = display_mode_scaling[display_index, i]
          }
          return display_mode_res[display_index, i]
        }
      }

      return ""
    }

    function build_arg(profile_index, display_index,   target_res, target_origin, target_degree) {
      target_res = choose_resolution(profile_index, display_index)
      if (target_res == "") {
        return ""
      }

      target_origin = display_origin[display_index]
      if (profile_origin[profile_index] != "") {
        target_origin = profile_origin[profile_index]
      }

      target_degree = display_degree[display_index]
      if (profile_degree[profile_index] != "") {
        target_degree = profile_degree[profile_index]
      }

      return "id:" display_id[display_index] " res:" target_res " enabled:true scaling:" resolved_scaling " origin:" target_origin " degree:" target_degree
    }

    function try_layout(layout_index,   i, profile_index, display_index, arg) {
      delete selected_args
      selected_count = 0

      for (i = 1; i <= layout_profile_count[layout_index]; i++) {
        profile_index = layout_profile[layout_index, i]
        display_index = find_display_for_profile(profile_index)
        if (display_index == 0) {
          return 0
        }

        arg = build_arg(profile_index, display_index)
        if (arg == "") {
          return 0
        }

        selected_count++
        selected_args[selected_count] = arg
      }

      return selected_count > 0
    }

    function emit_selected_layout(   layout_index, i) {
      for (layout_index = 1; layout_index <= layout_count; layout_index++) {
        if (!try_layout(layout_index)) {
          continue
        }

        printf("Selected display layout: %s\n", layout_name[layout_index]) > "/dev/stderr"
        for (i = 1; i <= selected_count; i++) {
          printf("%s\n", selected_args[i])
        }
        return 1
      }

      return 0
    }

    FILENAME == ARGV[1] {
      profile_count++
      profile_layout[profile_count] = $1
      profile_name[profile_count] = $3
      profile_match_type[profile_count] = $4
      profile_match_id[profile_count] = $5
      profile_match_name[profile_count] = $6
      profile_match_serial[profile_count] = $7
      profile_match_index[profile_count] = $8
      profile_resolution[profile_count] = $9
      profile_scaling[profile_count] = $10
      profile_origin[profile_count] = $11
      profile_degree[profile_count] = $12

      if (!seen_layout[$1]) {
        layout_count++
        seen_layout[$1] = layout_count
        layout_name[layout_count] = $2
      }

      layout_index = seen_layout[$1]
      layout_profile_count[layout_index]++
      layout_profile[layout_index, layout_profile_count[layout_index]] = profile_count
      next
    }

    FILENAME == ARGV[2] && FNR == 1 {
      FS = " "
    }

    FILENAME == ARGV[2] {
      if ($0 ~ /^Persistent screen id:/) {
        store_display()
        reset_display()
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
        sub(/[[:space:]]+-.*$/, "", origin)
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
      store_display()
      if (!emit_selected_layout()) {
        exit 1
      }
    }
  ' "$layout_tsv" "$display_list_file"
)

if [ "${#display_args[@]}" -eq 0 ]; then
  printf 'No matching display layout found.\n' >&2
  exit 1
fi

printf 'displayplacer'
printf ' %q' "${display_args[@]}"
printf '\n'

if [ "$mode" = "dry-run" ]; then
  exit 0
fi

"$displayplacer_bin" "${display_args[@]}"
