#!/usr/bin/env zsh -f

set -e
trap 'sketchybar --trigger task_update 2>/dev/null || true' EXIT

SYNC_DB="$HOME/.task/reminder-syncer.sqlite3"
FILTER_LISTS="Avilen|Todos"
LOG_FILE="/tmp/taskwarrior-hooks.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [on-modify] $1" >>"$LOG_FILE"
}

input=$(cat)
old_data=$(echo "$input" | sed -n '1p')
new_data=$(echo "$input" | sed -n '2p')

log "Old: $old_data"
log "New: $new_data"

if [ -n "${TASK_SYNC_RUNNING:-}" ]; then
    log "Sync running, skipping hook"
    echo "$new_data"
    exit 0
fi

uuid=$(echo "$old_data" | jq -r '.uuid')
old_status=$(echo "$old_data" | jq -r '.status // empty')
new_status=$(echo "$new_data" | jq -r '.status // empty')

# Escape for SQL
escaped_uuid="${uuid//\'/\'\'}"

external_id=$(sqlite3 "$SYNC_DB" "SELECT external_id FROM sync_keys WHERE uuid = '$escaped_uuid';" 2>/dev/null || echo "")
list=$(sqlite3 "$SYNC_DB" "SELECT list FROM sync_keys WHERE uuid = '$escaped_uuid';" 2>/dev/null || echo "")

if [ -z "$external_id" ]; then
    log "No external_id found for uuid: $uuid, skipping"
    echo "$new_data"
    exit 0
fi

log "Found external_id: $external_id, list: $list"

if [ "$new_status" = "deleted" ]; then
    log "Task deleted, removing from Reminders"
    reminders delete "$list" "$external_id" 2>/dev/null || log "Failed to delete reminder"
    sqlite3 "$SYNC_DB" "DELETE FROM sync_keys WHERE uuid = '$escaped_uuid';"
    echo "$new_data"
    exit 0
fi

if [ "$new_status" = "completed" ] && [ "$old_status" != "completed" ]; then
    log "Task completed, completing in Reminders"
    reminders complete "$list" "$external_id" 2>/dev/null || log "Failed to complete reminder"
    sqlite3 "$SYNC_DB" "UPDATE sync_keys SET tracking = 0 WHERE uuid = '$escaped_uuid';"
    echo "$new_data"
    exit 0
fi

if [ "$new_status" = "pending" ] && [ "$old_status" = "completed" ]; then
    log "Task uncompleted, uncompleting in Reminders"
    reminders uncomplete "$list" "$external_id" 2>/dev/null || log "Failed to uncomplete reminder"
    sqlite3 "$SYNC_DB" "UPDATE sync_keys SET tracking = 1 WHERE uuid = '$escaped_uuid';"
    echo "$new_data"
    exit 0
fi

log "Task modified, recreating in Reminders"
reminders delete "$list" "$external_id" 2>/dev/null || log "Failed to delete old reminder"

description=$(echo "$new_data" | jq -r '.description // empty')
new_project=$(echo "$new_data" | jq -r '.project // empty')
due=$(echo "$new_data" | jq -r '.due // empty')
priority=$(echo "$new_data" | jq -r '.priority // empty')
notes=$(echo "$new_data" | jq -r '.annotations[0].description // empty')

# Default project
if [ -z "$new_project" ]; then
    new_project="Todos"
    log "No project specified, using default: $new_project"
fi

if ! echo "$new_project" | grep -qE "^($FILTER_LISTS)$"; then
    log "New project '$new_project' not in filter list, removing from DB"
    sqlite3 "$SYNC_DB" "DELETE FROM sync_keys WHERE uuid = '$escaped_uuid';"
    echo "$new_data"
    exit 0
fi

# Build command args
args=("$new_project" "$description" --format json)

if [ -n "$due" ]; then
    due_iso="${due:0:4}-${due:4:2}-${due:6:2}T${due:9:2}:${due:11:2}:${due:13:2}Z"
    args+=(-d "$due_iso")
fi

if [ -n "$priority" ]; then
    case "$priority" in
    H) args+=(-p high) ;;
    M) args+=(-p medium) ;;
    L) args+=(-p low) ;;
    esac
fi

if [ -n "$notes" ]; then
    args+=(-n "$notes")
fi

log "Running: reminders add ${args[*]}"

result=$(reminders add "${args[@]}" 2>&1) || {
    log "Error: $result"
    echo "$new_data"
    exit 0
}

new_external_id=$(echo "$result" | jq -r '.externalId // empty')

if [ -z "$new_external_id" ]; then
    log "Failed to get external_id from result: $result"
    echo "$new_data"
    exit 0
fi

log "Created new reminder with externalId: $new_external_id"

# Escape for SQL
escaped_new_external_id="${new_external_id//\'/\'\'}"
escaped_new_project="${new_project//\'/\'\'}"

sqlite3 "$SYNC_DB" "UPDATE sync_keys SET external_id = '$escaped_new_external_id', list = '$escaped_new_project' WHERE uuid = '$escaped_uuid';"

echo "$new_data"
