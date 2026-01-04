#!/usr/bin/env zsh

source "$SKETCHYBAR_CONFIG_DIR/utils.sh"

update() {
  sketchybar --set calendar icon="$(date '+%a %d. %b')" label="$(date '+%H:%M')"
}

case "$SENDER" in
  "routine"|"system_woke"|"forced") update ;;
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
