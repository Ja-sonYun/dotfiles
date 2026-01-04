#!/usr/bin/env zsh

source "$SKETCHYBAR_CONFIG_DIR/utils.sh"
source "$SKETCHYBAR_CONFIG_DIR/settings.sh"

now=$(date +%s)

output=$(icalpal eventsToday \
  --iep type,title,sseconds,eseconds,all_day \
  --nb | gawk -v now="$now" -v reminder_sec="$CALENDAR_REMINDER_SECONDS" \
  -f "$SKETCHYBAR_CONFIG_DIR/scripts/calendar_parse.awk")

# First line: CURRENT_EVENT=...
current_event="${output%%$'\n'*}"
current_event="${current_event#CURRENT_EVENT=}"

# Rest: sketchybar commands
sketchybar_cmd="${output#*$'\n'}"

# Render popup
eval "sketchybar $sketchybar_cmd"

# Current event label
if [[ -n "$current_event" ]]; then
  label=$(truncate_width "$current_event" 28)
  sketchybar --set calendar y_offset=4 \
             --set calendar.event label="$label" drawing=on icon="􀧞"
else
  sketchybar --set calendar y_offset=0 \
             --set calendar.event label="" drawing=on icon=""
fi
