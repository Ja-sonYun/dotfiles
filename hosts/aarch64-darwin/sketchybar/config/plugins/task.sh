#!/usr/bin/env zsh

source "$SKETCHYBAR_CONFIG_DIR/colors.sh"
source "$SKETCHYBAR_CONFIG_DIR/utils.sh"

update() {
  output=$(task status:pending export 2>/dev/null | jq -r -f "$SKETCHYBAR_CONFIG_DIR/scripts/task_parse.jq")

  # First line: COUNT=n
  count="${output%%$'\n'*}"
  count="${count#COUNT=}"

  # Rest: sketchybar commands for task items (join lines)
  sketchybar_cmd="${output#*$'\n'}"
  sketchybar_cmd="${sketchybar_cmd//$'\n'/ }"

  # Set color based on count
  if [ "$count" -eq "0" ]; then
    label="􀆅"
    color=$GREEN
  else
    label="$count"
    color=$WHITE
  fi

  # Build full command
  cmd="sketchybar --remove '/task.items\.*/' $sketchybar_cmd"
  cmd+=" --clone task.items.fetcher task.template"
  cmd+=" --set task.items.fetcher label='Open Reminder' icon=􀷾 label.font='SF Pro:Bold:14.0' drawing=on position=popup.task click_script='open -a Reminders'"
  cmd+=" --set task label=$label label.color=$color"
  cmd+=" --animate tanh 15 --set task label.y_offset=5 label.y_offset=0"

  eval "$cmd"
}

case "$SENDER" in
  "routine"|"forced"|"task_update") update ;;
  "mouse.entered")
    cancel_popup_timer
    popup on
    start_popup_timer
    ;;
  "mouse.exited.global"|"mouse.exited")
    cancel_popup_timer
    popup off
    ;;
  "mouse.clicked") popup toggle ;;
esac
