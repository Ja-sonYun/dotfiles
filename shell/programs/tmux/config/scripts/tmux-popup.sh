#!/bin/sh

if tmux show-environment MAIN_POPUP >/dev/null 2>&1; then
    IS_MAIN_ATTACHED=$(tmux list-sessions | grep '^main:' | grep '(attached)')

    if [ -n "$IS_MAIN_ATTACHED" ]; then
        tmux detach-client
    else
        tmux switch-client -t main
    fi
else
    if [ "$1" = "top" ] || [ "$1" = "bottom" ]; then
        tmux popup -e POPUP=1 -w75% -h70% -E "tmux attach -t popup || tmux new -s popup -e MAIN_POPUP=1 -e DEFAULT=1"
    fi
fi
