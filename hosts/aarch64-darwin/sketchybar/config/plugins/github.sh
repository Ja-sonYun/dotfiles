#!/usr/bin/env zsh

source "$SKETCHYBAR_CONFIG_DIR/colors.sh"
source "$SKETCHYBAR_CONFIG_DIR/icons.sh"
source "$SKETCHYBAR_CONFIG_DIR/utils.sh"

update() {
  NOTIFICATIONS="$(gh api notifications 2>&1)" || {
    sketchybar --set $NAME icon=$BELL label="!"
    exit 0
  }

  COUNT="$(echo "$NOTIFICATIONS" | jq 'length')"
  local args=()

  if [ "$NOTIFICATIONS" = "[]" ]; then
    args+=(--set $NAME icon=$BELL label="0")
  else
    args+=(--set $NAME icon=$BELL_DOT label="$COUNT")
  fi

  PREV_COUNT=$(sketchybar --query github.bell | jq -r .label.value 2>/dev/null)
  args+=(--remove '/github.notification\.*/')

  COUNTER=0
  COLOR=$BLUE
  args+=(--set github.bell icon.color=$COLOR)

  while read -r repo url type title
  do
    COUNTER=$((COUNTER + 1))
    IMPORTANT="$(echo "$title" | grep -Ei "(deprecat|break|broke)")"
    COLOR=$BLUE
    PADDING=0

    if [ "${repo}" = "" ] && [ "${title}" = "" ]; then
      repo="Note"
      title="No new notifications"
    fi

    case "${type}" in
      "'Issue'")
        COLOR=$GREEN
        ICON=$GIT_ISSUE
        URL="$(gh api "$(strip_quotes "$url")" | jq .html_url)"
      ;;
      "'Discussion'")
        COLOR=$WHITE
        ICON=$GIT_DISCUSSION
        URL="https://www.github.com/notifications"
      ;;
      "'PullRequest'")
        COLOR=$MAGENTA
        ICON=$GIT_PULL_REQUEST
        URL="$(gh api "$(strip_quotes "$url")" | jq .html_url)"
      ;;
      "'Commit'")
        COLOR=$WHITE
        ICON=$GIT_COMMIT
        URL="$(gh api "$(strip_quotes "$url")" | jq .html_url)"
      ;;
      *)
        COLOR=$GREY
        ICON=$GIT_INDICATOR
      ;;
    esac

    if [ "$IMPORTANT" != "" ]; then
      COLOR=$RED
      ICON=􀁞
      args+=(--set github.bell icon.color=$COLOR)
    fi

    args+=(--clone github.notification.$COUNTER github.template \
           --set github.notification.$COUNTER label="$(strip_quotes "$title")" \
                                            icon="$ICON $(strip_quotes "$repo"):" \
                                            icon.padding_left="$PADDING" \
                                            label.padding_right="$PADDING" \
                                            icon.color=$COLOR \
                                            position=popup.github.bell \
                                            icon.background.color=$COLOR \
                                            drawing=on \
                                            click_script="open $URL;
                                                          sketchybar --set github.bell popup.drawing=off")
  done <<< "$(echo "$NOTIFICATIONS" | jq -r '.[] | [.repository.name, .subject.latest_comment_url, .subject.type, .subject.title] | @sh')"

  sketchybar -m "${args[@]}" > /dev/null

  if [ $COUNT -gt $PREV_COUNT ] 2>/dev/null || [ "$SENDER" = "forced" ]; then
    sketchybar --animate tanh 15 --set github.bell label.y_offset=5 label.y_offset=0
  fi
}

case "$SENDER" in
  "routine"|"forced") update ;;
  "mouse.entered")
    cancel_popup_timer
    popup on
    start_popup_timer
    ;;
  "mouse.exited.global"|"mouse.exited")
    cancel_popup_timer
    popup off
    ;;
  "mouse.clicked") popup toggle ;;
esac
