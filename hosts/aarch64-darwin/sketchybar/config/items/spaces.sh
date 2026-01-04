#!/usr/bin/env zsh

SPACE_ICONS=("1" "2" "3" "4" "5" "6" "7" "8" "9" "10" "11" "12" "13" "14" "15")

for (( i = 1; i <= ${#SPACE_ICONS}; i++ )); do
  sid=$i
  space_props=(
    associated_space=$sid
    icon=${SPACE_ICONS[i]}
    icon.padding_left=10
    icon.padding_right=15
    padding_left=2
    padding_right=2
    label.padding_right=20
    icon.highlight_color=$RED
    label.font="sketchybar-app-font:Regular:16.0"
    label.background.height=26
    label.background.drawing=on
    label.background.color=$BACKGROUND_2
    label.background.corner_radius=8
    label.drawing=off
    script="$PLUGIN_DIR/space.sh"
  )

  sketchybar --add space space.$sid left \
             --set space.$sid "${space_props[@]}" \
             --subscribe space.$sid mouse.clicked
done

spaces_bracket=(
  background.color=$BACKGROUND_1
  background.border_color=$BACKGROUND_2
  background.border_width=2
  background.drawing=on
)

sketchybar --add bracket spaces '/space\..*/' \
           --set spaces "${spaces_bracket[@]}"

separator=(
  icon=:chevron_right:
  icon.font="sketchybar-app-font:Regular:16.0"
  padding_left=17
  padding_right=10
  label.drawing=off
  associated_display=active
  click_script='yabai -m space --create && sketchybar --trigger space_change'
  icon.color=$WHITE
)

sketchybar --add item separator left --set separator "${separator[@]}"
