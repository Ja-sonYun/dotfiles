#!/usr/bin/osascript

tell application "System Events" to tell process "Control Center"
    click (first menu bar item of menu bar 1 whose description is "Control Center")
end tell
