#!/usr/bin/env zsh

sketchybar \
           --add item     calendar right                          \
           --set calendar icon=cal                                \
                          icon.font="$FONT:Black:12.0"            \
                          icon.padding_right=0                    \
                          label.width=45                          \
                          label.align=right                       \
                          padding_left=12                         \
                          update_freq=30                          \
                          popup.align=right                       \
                          popup.height=25                         \
                          script="$PLUGIN_DIR/calendar.zsh"       \
                          click_script="open -a Calendar"         \
           --subscribe calendar                                   \
                          system_woke                             \
                          mouse.entered                           \
                          mouse.exited.global                     \
           --add item     calendar.template popup.calendar        \
           --set calendar.template                                \
                          drawing=off                             \
                          icon.color=$ORANGE                      \
           --add item     calendar.template_now popup.calendar    \
           --set calendar.template_now                            \
                          drawing=off                             \
                          icon.color=$GREEN                       \
           --add item     calendar.event right                    \
           --set calendar.event                                   \
                          y_offset=-10                            \
                          width=0                                 \
                          update_freq=270                         \
                          script="$PLUGIN_DIR/calendar_event.zsh" \
                          label.font="$FONT:Black:7.0"            \
                          icon.font="$FONT:Heavy:7.0"             \
                          icon.color=$ORANGE                      \
                          icon.padding_right=-1                   \
                          icon=""                                 \
                          padding_right=-135                      \
                          drawing=on                              \
