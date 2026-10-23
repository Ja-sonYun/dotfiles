#!/usr/bin/env bash
set -euo pipefail

mode=$1
source_app=$2
target_user=$3
target=/Applications/Slack.app
vendor=/Applications/_Slack/Slack.app
bundle_id=com.user.slack-launcher

if [[ -n "${DRY_RUN:-}" ]]; then
	exit 0
fi

current_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)
if [[ "$mode" == disable ]]; then
	if [[ "$current_id" == "$bundle_id" ]]; then
		/bin/launchctl asuser "$(/usr/bin/id -u "$target_user")" \
			/usr/bin/sudo -u "$target_user" --set-home \
			"$target/Contents/MacOS/slack-launcher" --unregister
		/bin/rm -rf "$target"
	fi
	exit 0
fi

if [[ ! -x "$vendor/Contents/MacOS/Slack" ]]; then
	echo 'Slack is not installed at /Applications/_Slack/Slack.app. Quit Slack and reinstall its Homebrew cask with --appdir=/Applications/_Slack before activating.' >&2
	exit 1
fi
if [[ -e "$target" || -L "$target" ]] && [[ "$current_id" != "$bundle_id" ]]; then
	echo 'Refusing to replace /Applications/Slack.app: it is not the managed launcher. Complete the Homebrew relocation first. If only an empty directory remains, remove that directory manually.' >&2
	exit 1
fi

# Stage and sign a complete app before replacing the managed launcher.
staged=$(/usr/bin/mktemp -d /Applications/.slack-launcher.XXXXXX)
trap '/bin/rm -rf "$staged"' EXIT
/bin/cp -R "$source_app" "$staged/Slack.app"
/bin/chmod -R u+w "$staged"
icon=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$vendor/Contents/Info.plist")
if [[ "$icon" != *.icns ]]; then
	icon="$icon.icns"
fi
/bin/cp "$vendor/Contents/Resources/$icon" "$staged/Slack.app/Contents/Resources/Slack.icns"
/usr/bin/codesign --force --sign - "$staged/Slack.app"
if [[ "$current_id" == "$bundle_id" ]]; then
	/bin/rm -rf "$target"
fi
/bin/mv "$staged/Slack.app" "$target"
/bin/launchctl asuser "$(/usr/bin/id -u "$target_user")" \
	/usr/bin/sudo -u "$target_user" --set-home \
	"$target/Contents/MacOS/slack-launcher" --register
