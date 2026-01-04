# Parse taskwarrior JSON and generate sketchybar commands
# Input: task status:pending export
# Output: COUNT=n on first line, then sketchybar commands

# Sort by urgency descending
sort_by(.urgency) | reverse |

# Output count first
"COUNT=\(length)",

# Generate sketchybar commands for each task
(to_entries | .[] |
  .key as $i |
  .value as $t |
  ($t.tags[0] // "") as $tag |
  (if $tag != "" then "[\($tag)] " else "" end) as $tag_str |
  ($t.urgency | tostring) as $urg |
  ("\($tag_str)\($t.description), \($urg)" | @sh) as $label |

  "--clone task.items.\($i + 1) task.template",
  "--set task.items.\($i + 1) label=\($label) icon=􀀀 drawing=on position=popup.task click_script=\"sketchybar --set task.items.\($i + 1) icon=􀝜; task done \($t.id) && SENDER=forced \\$SKETCHYBAR_CONFIG_DIR/plugins/task.sh\""
)
