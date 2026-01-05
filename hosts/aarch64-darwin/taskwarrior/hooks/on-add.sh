#!/usr/bin/env zsh -f

set -e
trap 'sketchybar --trigger task_update 2>/dev/null || true' EXIT

SYNC_DB="$HOME/.task/reminder-syncer.sqlite3"
FILTER_LISTS="${FILTER_LISTS:-Todos|Work}"
LOG_FILE="/tmp/taskwarrior-hooks.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [on-add] $1" >>"$LOG_FILE"
}

input=$(cat)
log "Input: $input"

if [ -n "${TASK_SYNC_RUNNING:-}" ]; then
    log "Sync running, skipping hook"
    echo "$input"
    exit 0
fi

uuid=$(echo "$input" | jq -r '.uuid')
description=$(echo "$input" | jq -r '.description // empty')
project=$(echo "$input" | jq -r '.project // empty')
due=$(echo "$input" | jq -r '.due // empty')
priority=$(echo "$input" | jq -r '.priority // empty')
notes=$(echo "$input" | jq -r '.annotations[0].description // empty')

# Default project
if [ -z "$project" ]; then
    project="Todos"
    log "No project specified, using default: $project"
fi

if ! echo "$project" | grep -qE "^($FILTER_LISTS)$"; then
    log "Project '$project' not in filter list, skipping"
    echo "$input"
    exit 0
fi

# Build command args
args=("$project" "$description" --format json)

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
    echo "$input"
    exit 0
}

external_id=$(echo "$result" | jq -r '.externalId // empty')

if [ -z "$external_id" ]; then
    log "Failed to get external_id from result: $result"
    echo "$input"
    exit 0
fi

log "Created reminder with externalId: $external_id"

# Escape single quotes for SQL
escaped_uuid="${uuid//\'/\'\'}"
escaped_external_id="${external_id//\'/\'\'}"
escaped_project="${project//\'/\'\'}"

sqlite3 "$SYNC_DB" "CREATE TABLE IF NOT EXISTS sync_keys (
    id INTEGER PRIMARY KEY,
    uuid TEXT UNIQUE,
    external_id TEXT UNIQUE,
    list TEXT,
    tracking INTEGER DEFAULT 1
);"

sqlite3 "$SYNC_DB" "INSERT OR REPLACE INTO sync_keys (uuid, external_id, list, tracking) VALUES ('$escaped_uuid', '$escaped_external_id', '$escaped_project', 1);"

log "Stored mapping: $uuid -> $external_id"
echo "$input"
