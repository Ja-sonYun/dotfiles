#!/usr/bin/env zsh

function make_alias() {
  local name="$1"
  local click_script="$2"

  alias_props=(
    alias.color=$LABEL_COLOR
    drawing=on
    padding_right=-20
    padding_left=-2
    script='sketchybar --set calendar popup.drawing=off'
    click_script="$click_script"
  )

  sketchybar --add alias "$name" right \
             --set "$name" "${alias_props[@]}" \
             --subscribe "$name" mouse.entered
}

make_alias "Control Center,WiFi" "$SCRIPT_DIR/open_menubar_controlcenter.applescript"
