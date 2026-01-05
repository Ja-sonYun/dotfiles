#!/usr/bin/env zsh

calendar=(
  icon=cal
  icon.font="$FONT:Black:12.0"
  icon.padding_right=0
  label.width=45
  label.align=right
  padding_left=12
  update_freq=30
  popup.align=right
  popup.height=25
  script="$PLUGIN_DIR/calendar.sh"
  click_script="open -a Calendar"
)

sketchybar --add item calendar right \
           --set calendar "${calendar[@]}" \
           --subscribe calendar system_woke mouse.entered mouse.exited mouse.exited.global

calendar_template=(
  drawing=off
  icon.color=$ORANGE
)

sketchybar --add item calendar.template popup.calendar \
           --set calendar.template "${calendar_template[@]}"

calendar_template_now=(
  drawing=off
  icon.color=$GREEN
)

sketchybar --add item calendar.template_now popup.calendar \
           --set calendar.template_now "${calendar_template_now[@]}"

calendar_event=(
  y_offset=-10
  width=0
  update_freq=270
  script="$PLUGIN_DIR/calendar_event.sh"
  label.font="$FONT:Black:7.0"
  label.width=100
  label.scroll_texts=on
  label.scroll_duration=200
  icon.font="$FONT:Heavy:7.0"
  icon.color=$ORANGE
  icon.padding_right=-1
  icon=""
  padding_right=-135
  drawing=on
)

sketchybar --add item calendar.event right \
           --set calendar.event "${calendar_event[@]}" \
           --subscribe calendar.event mouse.entered mouse.exited mouse.exited.global
