#!/usr/bin/env zsh

cpu_top=(
  label.font="$FONT:Semibold:7"
  label=CPU
  icon.drawing=off
  width=0
  padding_right=15
  y_offset=6
  click_script="open -a 'Activity Monitor'"
)

sketchybar --add item cpu.top right --set cpu.top "${cpu_top[@]}"

cpu_percent=(
  label.font="$FONT:Heavy:12"
  label=CPU
  y_offset=-4
  padding_right=15
  width=55
  icon.drawing=off
  update_freq=2
  mach_helper="$HELPER"
)

sketchybar --add item cpu.percent right --set cpu.percent "${cpu_percent[@]}"

cpu_sys=(
  width=0
  graph.color=$RED
  graph.fill_color=$RED
  label.drawing=off
  icon.drawing=off
  background.height=30
  background.drawing=on
  background.color=$TRANSPARENT
)

sketchybar --add graph cpu.sys right 75 --set cpu.sys "${cpu_sys[@]}"

cpu_user=(
  graph.color=$BLUE
  label.drawing=off
  icon.drawing=off
  background.height=30
  background.drawing=on
  background.color=$TRANSPARENT
)

sketchybar --add graph cpu.user right 75 --set cpu.user "${cpu_user[@]}"
