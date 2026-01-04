#!/usr/bin/env zsh

sketchybar --add event github_update

github_bell=(
  update_freq=180
  icon.font="$FONT:Bold:15.0"
  icon=$BELL
  icon.color=$BLUE
  label=$LOADING
  label.highlight_color=$BLUE
  popup.align=right
  script="$PLUGIN_DIR/github.sh"
  click_script="open https://github.com/notifications"
)

sketchybar --add item github.bell right \
           --set github.bell "${github_bell[@]}" \
           --subscribe github.bell mouse.entered mouse.exited mouse.exited.global github_update

github_template=(
  drawing=off
  background.corner_radius=12
  padding_left=7
  padding_right=7
  icon.background.height=2
  icon.background.y_offset=-12
)

sketchybar --add item github.template popup.github.bell \
           --set github.template "${github_template[@]}"
