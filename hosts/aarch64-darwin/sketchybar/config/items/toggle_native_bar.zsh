#!/usr/bin/env zsh

sketchybar --add       item            togglenativebar center             \
           --set       togglenativebar                                    \
                                       icon.font="$FONT:Bold:15.0"        \
                                       icon=􀋰                             \
                                       icon.color=$BLUE                   \
                                       script="$PLUGIN_DIR/togglenativebar.zsh"   \
                                       click_script="$PLUGIN_DIR/togglenativebar.zsh" \
           --subscribe togglenativebar mouse.entered
