#!/bin/sh

schedules=$(icalpal eventsToday \
  --iep type,title,sseconds,eseconds,all_day \
  --nb | awk '
# parse raw blocks into TSV
function print_record() {
    if (!type) return
    if (is_all_day=="") is_all_day="0"
    print type, sseconds, eseconds, is_all_day, title
}

/^[^[:space:]]/ {
    if (type) print_record()
    type = $0; title = sseconds = eseconds = is_all_day = ""; next
}

/^[[:space:]]+[^[:space:]]/ && $1 !~ /sseconds:|eseconds:|all_day:/ {
    sub(/^[[:space:]]+/, ""); title = $0; next
}

/^[[:space:]]+sseconds: / {
    sub(/^[[:space:]]+sseconds: /, ""); sseconds = $0; next
}

/^[[:space:]]+eseconds: / {
    sub(/^[[:space:]]+eseconds: /, ""); eseconds = $0; next
}

/^[[:space:]]+all_day: / {
    sub(/^[[:space:]]+all_day: /, ""); is_all_day = $0; next
}

END { print_record() }
' OFS="\t" | sort -t$'\t' -k4,4nr -k2,2n)
now=$(date +%s)

function render() {
    args=(--remove '/calendar.lines\.*/')
    i=0
    while read -r type start_seconds end_seconds is_all_day title; do
        i=$((i+1))
        start_hour=$(date -r "$start_seconds" "+%H:%M")
        end_hour=$(date -r "$end_seconds" "+%H:%M")

        if [ "$is_all_day" = "1" ]; then
            time="All day"
        elif [ "$type" = "Reminders" ]; then
            time="◦ $start_hour"
        else
            time="• $start_hour ~ $end_hour"
        fi

        is_current_event="0"
        start_soon=$(( start_seconds - 900 ))
        if [ "$start_soon" -le "$now" ] && [ "$end_seconds" -ge "$now" ]; then
            if [ "$type" = "CalDAV" ] && [ "$is_all_day" = "0" ]; then
                is_current_event="1"
            fi
        fi

        # Add a new line to the sketchybar popup
        if [ "$is_current_event" = "1" ]; then
            args+=(--clone calendar.lines.$i calendar.template_now)
        else
            args+=(--clone calendar.lines.$i calendar.template)
        fi
        args+=(--set   calendar.lines.$i                            \
                                         icon="$time"               \
                                         label="$title"             \
                                         position=popup.calendar    \
                                         drawing=on)
    done <<< "$schedules"

    args+=(--animate tanh 15 --set calendar icon.y_offset=5 icon.y_offset=0)
    sketchybar -m "${args[@]}"
}

function current_event() {
    events_name=""

    while read -r type start_seconds end_seconds is_all_day title; do
        start_soon=$(( start_seconds - 900 ))
        if [ "$start_soon" -le "$now" ] && [ "$end_seconds" -ge "$now" ]; then
            if [ "$type" = "CalDAV" ] && [ "$is_all_day" = "0" ]; then
                events_name="$title"
            fi
        fi
    done <<< "$schedules"

    args=()

    events_name=$(perl -CS -Mutf8 -ne '
      use utf8;
      chomp;
      my $max_width = 28;
      my $out = "";
      my $width = 0;

      foreach my $c (split //, $_) {
        my $w = ($c =~ /[\x{1100}-\x{115F}\x{2E80}-\x{A4CF}\x{AC00}-\x{D7A3}\x{F900}-\x{FAFF}\x{FE10}-\x{FE6F}\x{FF00}-\x{FF60}\x{FFE0}-\x{FFE6}]/) ? 2 : 1;
        if ($width + $w > $max_width) {
          $out .= "...";
          last;
        }
        $out .= $c;
        $width += $w;
      }

      print $out;
    ' <<< "$events_name")

    if [ "$events_name" == "" ]; then
        args+=(--set calendar y_offset=0)
        args+=(--set calendar.event label="" drawing=on icon="")
    else
        events_name=$(echo "$events_name" | iconv -f utf-8 -t utf-8 -c)

        args+=(--set calendar y_offset=4)
        args+=(--set calendar.event label="$events_name" drawing=on icon="􀧞")
    fi

    sketchybar -m "${args[@]}"
}

render
current_event
