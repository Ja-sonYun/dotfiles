#!/bin/sh

tmux rename-session -t main _temp_current
tmux rename-session -t popup _temp_popup

tmux rename-session -t _temp_current popup
tmux rename-session -t _temp_popup main

tmux set-environment -t main -u MAIN_POPUP
tmux set-environment -t main MAIN 1

tmux set-environment -t popup -u MAIN
tmux set-environment -t popup MAIN_POPUP 1

tmux switch-client -t main
