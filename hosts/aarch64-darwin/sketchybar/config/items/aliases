#!/usr/bin/env zsh

function make_alias() {
    local name="$1"
    local click_script="$2"

    sketchybar --add alias "$1" right                                   \
        --set "$1" alias.color=$LABEL_COLOR                             \
                   drawing=on                                           \
                   padding_right=-20                                    \
                   padding_left=-2                                      \
                   script='sketchybar --set calendar popup.drawing=off' \
                   click_script="$click_script"                         \
        --subscribe "$1" mouse.entered
}

make_alias "Control Center,WiFi"                         "$PLUGIN_DIR/open_menubar_controlcenter"
