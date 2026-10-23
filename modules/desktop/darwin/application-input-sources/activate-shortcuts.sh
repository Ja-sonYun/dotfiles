# shellcheck shell=bash

# Preserve the shortcut's parameters and all other symbolic hotkeys.
entry=$(
	/usr/bin/defaults export com.apple.symbolichotkeys - |
	/usr/bin/plutil -extract AppleSymbolicHotKeys.60 xml1 -o - - |
	/usr/bin/plutil -replace enabled -bool "$1" -o - -
)
/usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 60 "$entry"
