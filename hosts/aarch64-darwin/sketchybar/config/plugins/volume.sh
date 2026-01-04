#!/usr/bin/env zsh

source "$SKETCHYBAR_CONFIG_DIR/settings.sh"

init() {
  VOLUME=$(osascript -e 'output volume of (get volume settings)')
  sketchybar --set $NAME slider.percentage=$VOLUME
}

volume_change() {
  sketchybar --set $NAME slider.percentage=$INFO \
             --animate tanh $ANIMATION_DURATION --set $NAME slider.width=$VOLUME_SLIDER_WIDTH

  sleep $VOLUME_HIDE_DELAY

  FINAL_PERCENTAGE=$(sketchybar --query $NAME | jq -r ".slider.percentage" 2>/dev/null)
  [[ -z "$FINAL_PERCENTAGE" ]] && exit 0

  if [ "$FINAL_PERCENTAGE" -eq "$INFO" ]; then
    sketchybar --animate tanh $ANIMATION_DURATION --set $NAME slider.width=0
  fi
}

mouse_clicked() {
  PERCENTAGE=$(sketchybar --query $NAME | jq -r ".slider.percentage" 2>/dev/null)
  [[ -z "$PERCENTAGE" ]] && exit 0
  osascript -e "set volume output volume $PERCENTAGE"
}

case "$SENDER" in
  "volume_change") volume_change ;;
  "mouse.clicked") mouse_clicked ;;
  "forced") init ;;
esac
