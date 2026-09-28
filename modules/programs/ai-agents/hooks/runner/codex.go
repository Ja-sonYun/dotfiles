package main

import (
	"encoding/json"
	"os"
)

var commonFields = []string{
	"agent_id", "agent_type", "cwd", "effort", "hook_event_name",
	"permission_mode", "prompt_id", "session_id", "transcript_path",
}

var eventFields = map[string][]string{
	"Notification":     {"message", "notification_type", "title"},
	"SessionStart":     {"model", "session_title", "source"},
	"UserPromptSubmit": {"prompt", "session_title"},
	"PreToolUse":       {"tool_input", "tool_name", "tool_use_id"},
	"PostToolUse":      {"duration_ms", "tool_input", "tool_name", "tool_response", "tool_use_id"},
	"PreCompact":       {"custom_instructions", "trigger"},
	"PostCompact":      {"compact_summary", "trigger"},
	"Stop":             {"background_tasks", "last_assistant_message", "session_crons", "stop_hook_active"},
	"SessionEnd":       {"reason"},
}

func translateCodex(input map[string]json.RawMessage, event, notification string) map[string]json.RawMessage {
	if event == "" {
		event = textField(input, "hook_event_name")
	}
	output := make(map[string]json.RawMessage)
	for _, fields := range [][]string{commonFields, eventFields[event]} {
		for _, name := range fields {
			if value, exists := input[name]; exists {
				output[name] = value
			}
		}
	}
	if event != "" {
		setText(output, "hook_event_name", event)
	}
	if _, exists := output["prompt_id"]; !exists {
		var turn *string
		if json.Unmarshal(input["turn_id"], &turn) == nil && turn != nil {
			setText(output, "prompt_id", *turn)
		}
	}
	if event == "Notification" && notification != "" {
		client := os.Getenv("AI_AGENT_CLIENT")
		if client == "" {
			client = "Codex"
		}
		message := client + " is waiting for input"
		if notification == "permission_prompt" {
			message = client + " is waiting for permission"
		}
		setText(output, "message", message)
		setText(output, "notification_type", notification)
		setText(output, "title", client)
	}
	return output
}
