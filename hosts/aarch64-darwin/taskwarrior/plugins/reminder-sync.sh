#!/usr/bin/env zsh -f
set -e

SYNC_DB="$HOME/.task/reminder-syncer.sqlite3"
FILTER_LISTS="Avilen Todos"
LOG_FILE="/tmp/taskwarrior-hooks.log"
TASK_BIN="${TASKWARRIOR_BIN:-task}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [sync] $1" >>"$LOG_FILE"
}

# Initialize DB
sqlite3 "$SYNC_DB" "CREATE TABLE IF NOT EXISTS sync_keys (
  id INTEGER PRIMARY KEY,
  uuid TEXT UNIQUE,
  external_id TEXT UNIQUE,
  list TEXT,
  tracking INTEGER DEFAULT 1
);"

log "Starting sync..."

# Get all reminders (fix invalid JSON with unescaped newlines)
all_reminders=$(reminders show-all --format json | python3 -c '
import sys
text = sys.stdin.read()
result = []
in_string = False
i = 0
while i < len(text):
    c = text[i]
    if c == "\"" and (i == 0 or text[i-1] != "\\"):
        in_string = not in_string
        result.append(c)
    elif c == "\n" and in_string:
        result.append("\\n")
    else:
        result.append(c)
    i += 1
print("".join(result))
')

# Process each list
for list in ${=FILTER_LISTS}; do
    log "Processing list: $list"

    # Filter reminders for this list
    list_reminders=$(print -r -- "$all_reminders" | jq -c ".[] | select(.list == \"$list\" and .isCompleted == false)")

    echo "$list_reminders" | while IFS= read -r reminder; do
        [ -z "$reminder" ] && continue

        external_id=$(echo "$reminder" | jq -r '.externalId')
        title=$(echo "$reminder" | jq -r '.title')
        due_date=$(echo "$reminder" | jq -r '.dueDate // empty')
        priority=$(echo "$reminder" | jq -r '.priority // 0')
        notes=$(echo "$reminder" | jq -r '.notes // empty')

        log "Processing reminder: $title (externalId: $external_id)"

        # Check if already tracked
        existing_uuid=$(sqlite3 "$SYNC_DB" "SELECT uuid FROM sync_keys WHERE external_id = '$external_id';" 2>/dev/null || echo "")

        if [ -n "$existing_uuid" ]; then
            log "Already tracked with uuid: $existing_uuid, updating..."

            # Build import JSON for update
            import_json=$(jq -n \
                --arg uuid "$existing_uuid" \
                --arg desc "$title" \
                --arg proj "$list" \
                '{uuid: $uuid, description: $desc, project: $proj, status: "pending"}')

            # Add due date if present
            if [ -n "$due_date" ]; then
                # Convert ISO to taskwarrior format
                due_tw=$(echo "$due_date" | sed 's/-//g; s/://g; s/\.[0-9]*Z/Z/')
                import_json=$(echo "$import_json" | jq --arg due "$due_tw" '. + {due: $due}')
            fi

            # Add priority if present
            if [ "$priority" -eq 1 ]; then
                import_json=$(echo "$import_json" | jq '. + {priority: "H"}')
            elif [ "$priority" -eq 5 ]; then
                import_json=$(echo "$import_json" | jq '. + {priority: "M"}')
            elif [ "$priority" -eq 9 ]; then
                import_json=$(echo "$import_json" | jq '. + {priority: "L"}')
            fi

            # Add notes as annotation if present
            if [ -n "$notes" ]; then
                import_json=$(echo "$import_json" | jq --arg notes "$notes" \
                    '. + {annotations: [{entry: (now | strftime("%Y%m%dT%H%M%SZ")), description: $notes}]}')
            fi

            log "Import JSON: $import_json"
            echo "$import_json" | "$TASK_BIN" import 2>/dev/null || log "Failed to import task"

        else
            log "New reminder, creating task..."

            # Generate new UUID
            new_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')

            # Build import JSON
            import_json=$(jq -n \
                --arg uuid "$new_uuid" \
                --arg desc "$title" \
                --arg proj "$list" \
                '{uuid: $uuid, description: $desc, project: $proj, status: "pending"}')

            if [ -n "$due_date" ]; then
                due_tw=$(echo "$due_date" | sed 's/-//g; s/://g; s/\.[0-9]*Z/Z/')
                import_json=$(echo "$import_json" | jq --arg due "$due_tw" '. + {due: $due}')
            fi

            if [ "$priority" -eq 1 ]; then
                import_json=$(echo "$import_json" | jq '. + {priority: "H"}')
            elif [ "$priority" -eq 5 ]; then
                import_json=$(echo "$import_json" | jq '. + {priority: "M"}')
            elif [ "$priority" -eq 9 ]; then
                import_json=$(echo "$import_json" | jq '. + {priority: "L"}')
            fi

            if [ -n "$notes" ]; then
                import_json=$(echo "$import_json" | jq --arg notes "$notes" \
                    '. + {annotations: [{entry: (now | strftime("%Y%m%dT%H%M%SZ")), description: $notes}]}')
            fi

            log "Import JSON: $import_json"
            echo "$import_json" | "$TASK_BIN" import 2>/dev/null || log "Failed to import task"

            # Store mapping
            sqlite3 "$SYNC_DB" "INSERT OR REPLACE INTO sync_keys (uuid, external_id, list, tracking) VALUES ('$new_uuid', '$external_id', '$list', 1);"
            log "Stored mapping: $new_uuid -> $external_id"
        fi
    done
done

# Handle completed/deleted reminders
log "Checking for completed/deleted reminders..."

sqlite3 "$SYNC_DB" "SELECT uuid, external_id, list FROM sync_keys WHERE tracking = 1;" | while IFS='|' read -r uuid external_id list; do
    [ -z "$uuid" ] && continue

    # Check if reminder still exists and is not completed
    exists=$(print -r -- "$all_reminders" | jq -r ".[] | select(.externalId == \"$external_id\" and .isCompleted == false) | .externalId" | head -1)

    if [ -z "$exists" ]; then
        # Check if completed
        completed=$(print -r -- "$all_reminders" | jq -r ".[] | select(.externalId == \"$external_id\" and .isCompleted == true) | .externalId" | head -1)

        if [ -n "$completed" ]; then
            log "Reminder $external_id completed, completing task $uuid"
            "$TASK_BIN" "$uuid" "done" 2>/dev/null || log "Failed to complete task"
            sqlite3 "$SYNC_DB" "UPDATE sync_keys SET tracking = 0 WHERE uuid = '$uuid';"
        else
            log "Reminder $external_id deleted, deleting task $uuid"
            "$TASK_BIN" "$uuid" "delete" 2>/dev/null || log "Failed to delete task"
            sqlite3 "$SYNC_DB" "DELETE FROM sync_keys WHERE uuid = '$uuid';"
        fi
    fi
done

log "Sync completed"
echo "Sync completed"
