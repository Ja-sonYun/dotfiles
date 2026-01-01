#!/bin/sh

SKETCHYBAR=$(which sketchybar)

topmost_off() {
    flock -en /tmp/sketchybar_show_native_bar.lock -c $SKETCHYBAR" --bar hidden=on && sleep 3 && "$SKETCHYBAR" --bar hidden=off"
}

case "$SENDER" in
  "mouse.entered") topmost_off ;;
esac
