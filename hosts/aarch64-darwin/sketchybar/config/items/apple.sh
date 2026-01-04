#!/usr/bin/env zsh

apple_logo=(
  icon=$APPLE
  icon.font="$FONT:Black:16.0"
  icon.color=$GREEN
  padding_right=15
  label.drawing=off
  click_script="$SCRIPT_DIR/open_menubar_apple.applescript"
)

sketchybar --add item apple.logo left --set apple.logo "${apple_logo[@]}"
