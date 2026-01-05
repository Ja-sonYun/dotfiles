#!/usr/bin/env zsh

# Remove surrounding single quotes from jq @sh output
strip_quotes() {
  echo "$1" | sed -e "s/^'//" -e "s/'$//"
}

# All items with popups
POPUP_ITEMS=(calendar github.bell task)

# Popup timer ID file
POPUP_TIMER_ID="/tmp/sketchybar_popup_timer_id"

# Start delayed popup close (5 seconds)
# Each timer has unique ID - only the latest timer closes popups
start_popup_timer() {
  local id="$$.$RANDOM"
  echo "$id" > "$POPUP_TIMER_ID"
  (
    sleep 5
    [[ "$(cat "$POPUP_TIMER_ID" 2>/dev/null)" != "$id" ]] && exit 0
    for item in "${POPUP_ITEMS[@]}"; do
      sketchybar --set "$item" popup.drawing=off
    done
  ) &
}

# Cancel popup timer by invalidating current ID
cancel_popup_timer() {
  echo "cancelled" > "$POPUP_TIMER_ID"
}

# Close all popups except current item
close_other_popups() {
  for item in "${POPUP_ITEMS[@]}"; do
    [[ "$item" != "$NAME" ]] && sketchybar --set "$item" popup.drawing=off
  done
}

# Common popup toggle handler
popup() {
  local state="$1"
  if [[ "$state" == "toggle" ]]; then
    local current=$(sketchybar --query "$NAME" | jq -r '.popup.drawing')
    state=$([[ "$current" == "on" ]] && echo "off" || echo "on")
  fi
  [[ "$state" == "on" ]] && close_other_popups
  sketchybar --set "$NAME" popup.drawing="$state"
}

# Truncate string by display width (CJK = 2, ASCII = 1)
truncate_width() {
  gawk -v max="$2" 'BEGIN {
    w = 0; r = ""
    s = ARGV[1]; delete ARGV[1]
    n = split(s, c, "")
    for (i = 1; i <= n; i++) {
      cw = (c[i] >= " " && c[i] <= "~") ? 1 : 2
      if (w + cw > max) { r = r "..."; break }
      w += cw; r = r c[i]
    }
    print r
  }' "$1"
}
