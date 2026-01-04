#!/usr/bin/env zsh

sketchybar --add event task_update

task=(
  update_freq=180
  script="$PLUGIN_DIR/task.sh"
  icon.color="$MAGENTA"
  icon=􀷾
  label="?"
  padding_right=10
  popup.align=right
  popup.height=30
)

sketchybar --add item task right \
           --set task "${task[@]}" \
           --subscribe task mouse.entered mouse.exited mouse.exited.global task_update

task_template=(
  drawing=off
  padding_left=7
  padding_right=7
  icon.color="$MAGENTA"
  icon.background.height=2
  icon.background.y_offset=-12
)

sketchybar --add item task.template popup.task \
           --set task.template "${task_template[@]}"
