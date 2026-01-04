#!/usr/bin/env gawk -f
# Calendar event parser for sketchybar
# Input: icalpal eventsToday output
# Variables: now (epoch), reminder_sec (seconds before event)

BEGIN {
    n = 0
    current_event = ""
}

# Parse icalpal block format
/^[^[:space:]]/ {
    if (type) save_record()
    type = $0
    title = sseconds = eseconds = is_all_day = ""
    next
}

/^[[:space:]]+[^[:space:]]/ && $1 !~ /sseconds:|eseconds:|all_day:/ {
    sub(/^[[:space:]]+/, "")
    title = $0
    next
}

/^[[:space:]]+sseconds: / {
    sub(/^[[:space:]]+sseconds: /, "")
    sseconds = $0
    next
}

/^[[:space:]]+eseconds: / {
    sub(/^[[:space:]]+eseconds: /, "")
    eseconds = $0
    next
}

/^[[:space:]]+all_day: / {
    sub(/^[[:space:]]+all_day: /, "")
    is_all_day = $0
    next
}

function save_record() {
    if (!type) return
    if (is_all_day == "") is_all_day = "0"
    n++
    records[n, "type"] = type
    records[n, "title"] = title
    records[n, "sseconds"] = sseconds
    records[n, "eseconds"] = eseconds
    records[n, "is_all_day"] = is_all_day
}

function sort_records(    i, j, tmp, key) {
    # Bubble sort: all_day desc, then sseconds asc
    for (i = 1; i < n; i++) {
        for (j = i + 1; j <= n; j++) {
            swap = 0
            # All day events first
            if (records[i, "is_all_day"] < records[j, "is_all_day"]) {
                swap = 1
            } else if (records[i, "is_all_day"] == records[j, "is_all_day"]) {
                # Then by start time
                if (records[i, "sseconds"] > records[j, "sseconds"]) {
                    swap = 1
                }
            }
            if (swap) {
                for (key in records) {
                    split(key, parts, SUBSEP)
                    if (parts[1] == i) {
                        tmp[parts[2]] = records[i, parts[2]]
                    }
                }
                for (key in records) {
                    split(key, parts, SUBSEP)
                    if (parts[1] == i) {
                        records[i, parts[2]] = records[j, parts[2]]
                    }
                }
                for (k in tmp) {
                    records[j, k] = tmp[k]
                }
                delete tmp
            }
        }
    }
}

function is_current(type, sseconds, eseconds, is_all_day) {
    if (type != "CalDAV" || is_all_day == "1") return 0
    start_soon = sseconds - reminder_sec
    return (start_soon <= now && eseconds >= now)
}

function escape_shell(str) {
    gsub(/'/, "'\\''", str)
    return str
}

END {
    save_record()
    sort_records()

    # Build sketchybar commands
    cmd = "--remove '/calendar.lines\\.*/' "

    for (i = 1; i <= n; i++) {
        type = records[i, "type"]
        title = records[i, "title"]
        sseconds = records[i, "sseconds"]
        eseconds = records[i, "eseconds"]
        is_all_day = records[i, "is_all_day"]

        # Format time
        if (is_all_day == "1") {
            time_str = "All day"
        } else if (type == "Reminders") {
            time_str = "◦ " strftime("%H:%M", sseconds)
        } else {
            time_str = "• " strftime("%H:%M", sseconds) " ~ " strftime("%H:%M", eseconds)
        }

        # Check if current event
        template = "calendar.template"
        if (is_current(type, sseconds, eseconds, is_all_day)) {
            template = "calendar.template_now"
            if (current_event == "") current_event = title
        }

        # Build command
        cmd = cmd "--clone calendar.lines." i " " template " "
        cmd = cmd "--set calendar.lines." i " "
        cmd = cmd "icon='" escape_shell(time_str) "' "
        cmd = cmd "label='" escape_shell(title) "' "
        cmd = cmd "position=popup.calendar drawing=on "
    }

    cmd = cmd "--animate tanh 15 --set calendar icon.y_offset=5 icon.y_offset=0"

    # Output
    print "CURRENT_EVENT=" current_event
    print cmd
}
