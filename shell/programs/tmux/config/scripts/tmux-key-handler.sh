#!/bin/bash

KEY="$1"

# Error notification function
notify_error() {
    local cmd="$1"
    tmux display-message "Failed to execute '$cmd'"
}

case "$KEY" in
"nC-d")
    if tmux show-environment TMUX_REMAP_CTRL_D >/dev/null 2>&1; then
        REMAP=$(tmux show-environment TMUX_REMAP_CTRL_D | cut -d= -f2-)
        tmux send-keys "$REMAP" || notify_error "send-keys $REMAP"
    else
        tmux send-keys C-d || notify_error "send-keys C-d"
    fi
    ;;

"nC-c")
    # Control-C handling for new window
    if tmux show-environment CTRL_C_AS_CLOSE >/dev/null 2>&1; then
        tmux detach || notify_error "detach"
    else
        tmux send-keys C-c || notify_error "send-keys C-c"
    fi
    ;;
"C-c")
    # Control-C handling
    if tmux show-environment CTRL_C_AS_CLOSE >/dev/null 2>&1; then
        tmux send-keys C-c || notify_error "send-keys C-c"
    fi
    ;;

"c")
    # New window handling
    # If MULTI_SESSION_COMMAND exists, create new window with that command
    if tmux show-environment MULTI_SESSION_COMMAND >/dev/null 2>&1; then
        COMMAND=$(tmux show-environment MULTI_SESSION_COMMAND | cut -d= -f2-)
        tmux new-window "$COMMAND" || notify_error "new-window with command"
    # If NO_WINDOW_MGNT exists, detach (disable window management)
    elif tmux show-environment NO_WINDOW_MGNT >/dev/null 2>&1; then
        tmux detach || notify_error "detach"
    else
        # Default: create normal new window
        tmux new-window || notify_error "new-window"
    fi
    ;;

"n")
    # Next window
    if tmux show-environment MULTI_SESSION_COMMAND >/dev/null 2>&1; then
        tmux next-window || notify_error "next-window"
    elif tmux show-environment NO_WINDOW_MGNT >/dev/null 2>&1; then
        tmux detach || notify_error "detach"
    else
        tmux next-window || notify_error "next-window"
    fi
    ;;

"p")
    # Previous window
    if tmux show-environment MULTI_SESSION_COMMAND >/dev/null 2>&1; then
        tmux previous-window || notify_error "previous-window"
    elif tmux show-environment NO_WINDOW_MGNT >/dev/null 2>&1; then
        tmux detach || notify_error "detach"
    else
        tmux previous-window || notify_error "previous-window"
    fi
    ;;

"w")
    # Window tree
    if tmux show-environment MENU_POPUP >/dev/null 2>&1; then
        tmux detach || notify_error "detach"
    else
        tmux choose-tree -Zw || notify_error "choose-tree -Zw"
    fi
    ;;

"s")
    # Session tree
    if tmux show-environment MENU_POPUP >/dev/null 2>&1; then
        tmux detach || notify_error "detach"
    else
        tmux choose-tree -Zs || notify_error "choose-tree -Zs"
    fi
    ;;

"d")
    # Detach handling
    if tmux show-environment DEFAULT >/dev/null 2>&1; then
        # Cannot detach on default sessions - do nothing
        :
    else
        tmux detach || notify_error "detach"
    fi
    ;;

"%")
    # Horizontal split handling
    if tmux show-environment NO_WINDOW_MGNT >/dev/null 2>&1; then
        tmux detach || notify_error "detach"
    else
        tmux split-window -h || notify_error "split-window -h"
    fi
    ;;

'"')
    # Vertical split handling
    if tmux show-environment NO_WINDOW_MGNT >/dev/null 2>&1; then
        tmux detach || notify_error "detach"
    else
        tmux split-window || notify_error "split-window"
    fi
    ;;

"!")
    # Break pane handling
    if tmux show-environment NO_WINDOW_MGNT >/dev/null 2>&1; then
        tmux detach || notify_error "detach"
    else
        tmux break-pane || notify_error "break-pane"
    fi
    ;;

"k")
    # Show menu handling
    pane_current_path=$(tmux display-message -p "#{pane_current_path}")

    if tmux show-environment DEFAULT >/dev/null 2>&1; then
        tmux-menu show --menu "$TMUX_CONFIG"/menu/menu.yaml --working_dir "$pane_current_path" || notify_error "tmux-menu show"
    else
        tmux detach || notify_error "detach"
        W=$(tmux display -p "#{client_width}")
        W=$((W - 1))
        H=$(tmux display -p "#{client_height}")
        tmux-menu show -x "$W" -y "$H" --menu "$TMUX_CONFIG"/menu/menu.yaml --working_dir "$pane_current_path" || notify_error "tmux-menu show"
    fi
    ;;

*)
    echo "Unknown key: $KEY" >&2
    exit 1
    ;;
esac
