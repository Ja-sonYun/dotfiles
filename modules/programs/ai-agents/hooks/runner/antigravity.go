package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

func runAntigravity(input map[string]json.RawMessage, event, command string, timeout int) int {
	output := make(map[string]json.RawMessage)
	output["reported_at"] = input["reported_at"]
	output["event_id"] = input["event_id"]
	setText(output, "hook_event_name", event)
	setText(output, "session_id", textField(input, "conversationId"))
	setText(output, "transcript_path", textField(input, "transcriptPath"))
	var paths []string
	if json.Unmarshal(input["workspacePaths"], &paths) == nil && len(paths) > 0 {
		setText(output, "cwd", paths[0])
	}
	var tool map[string]json.RawMessage
	if json.Unmarshal(input["toolCall"], &tool) == nil {
		name := textField(tool, "name")
		var args map[string]json.RawMessage
		if json.Unmarshal(tool["args"], &args) == nil && args != nil {
			// Adapt native editing arguments to the shared edit/rules contract.
			fields := map[string]string{}
			switch name {
			case "run_command":
				name = "Bash"
				fields = map[string]string{"CommandLine": "command", "Cwd": "cwd"}
			case "view_file":
				name = "Read"
				fields = map[string]string{"AbsolutePath": "file_path"}
			case "write_to_file":
				name = "Write"
				fields = map[string]string{"TargetFile": "file_path", "CodeContent": "content"}
			case "replace_file_content":
				name = "Edit"
				fields = map[string]string{"TargetFile": "file_path", "TargetContent": "old_string", "ReplacementContent": "new_string", "AllowMultiple": "replace_all"}
			case "multi_replace_file_content":
				name = "MultiEdit"
				fields = map[string]string{"TargetFile": "file_path"}
				var chunks []map[string]json.RawMessage
				if json.Unmarshal(args["ReplacementChunks"], &chunks) == nil {
					for _, chunk := range chunks {
						chunk["old_string"] = chunk["TargetContent"]
						chunk["new_string"] = chunk["ReplacementContent"]
						if value, exists := chunk["AllowMultiple"]; exists {
							chunk["replace_all"] = value
						}
					}
					args["edits"], _ = json.Marshal(chunks)
				}
			}
			for native, canonical := range fields {
				if value, exists := args[native]; exists {
					args[canonical] = value
				}
			}
			output["tool_input"], _ = json.Marshal(args)
		} else {
			output["tool_input"] = tool["args"]
		}
		setText(output, "tool_name", name)
	}
	if step, exists := input["stepIdx"]; exists {
		setText(output, "tool_use_id", textField(input, "conversationId")+":"+string(step))
	}
	errorValue := string(input["error"])
	failed := errorValue != "" && errorValue != "null" && errorValue != `""` && errorValue != "false"
	if event == "PostToolUse" && failed {
		output["tool_failed"] = json.RawMessage("true")
	}
	if event == "Stop" || event == "StopFailure" {
		reason := textField(input, "terminationReason")
		setText(output, "termination_reason", reason)
		if idle, exists := input["fullyIdle"]; exists {
			output["fully_idle"] = idle
		}
		failed = failed || reason == "error" || reason == "max_steps_exceeded"
		if (event == "StopFailure" && !failed) || (event == "Stop" && (failed || reason != "model_stop" || string(input["fullyIdle"]) == "false")) {
			return writeAntigravityResponse(event, "stop", "")
		}
		if failed {
			setText(output, "outcome", "error")
		} else {
			setText(output, "outcome", "completed")
		}
	}
	data, err := encodeJSON(output)
	if err != nil {
		return writeAntigravityResponse(event, "deny", "Cannot encode Antigravity hook input: "+err.Error())
	}
	// Capture stdout while retaining the shared runner's process-group cancellation.
	file, err := os.CreateTemp("", "antigravity-hook-*")
	if err != nil {
		return writeAntigravityResponse(event, "deny", "Cannot capture hook response: "+err.Error())
	}
	defer os.Remove(file.Name())
	defer file.Close()
	quotedPath := "'" + strings.ReplaceAll(file.Name(), "'", "'\"'\"'") + "'"
	status := runCommand("{\n"+command+"\n} >"+quotedPath, data, timeout, false)
	responseData, err := io.ReadAll(io.LimitReader(file, 64*1024+1))
	if err != nil || len(responseData) > 64*1024 || status != 0 {
		message := fmt.Sprintf("Hook failed or returned invalid output (exit %d); the tool was not approved.", status)
		return writeAntigravityResponse(event, "deny", message)
	}
	var response map[string]json.RawMessage
	if len(bytes.TrimSpace(responseData)) != 0 && (json.Unmarshal(responseData, &response) != nil || response == nil) {
		return writeAntigravityResponse(event, "deny", "Hook returned invalid JSON; the tool was not approved.")
	}
	var specific map[string]json.RawMessage
	if value, exists := response["hookSpecificOutput"]; exists {
		if json.Unmarshal(value, &specific) != nil || specific == nil {
			return writeAntigravityResponse(event, "deny", "Hook returned invalid hookSpecificOutput.")
		}
	}
	message := strings.TrimSpace(strings.Join([]string{
		textField(response, "reason"),
		textField(response, "stopReason"),
		textField(specific, "permissionDecisionReason"),
		textField(specific, "additionalContext"),
	}, "\n\n"))
	decision := "allow"
	if event == "Stop" || event == "StopFailure" {
		decision = "stop"
		if event == "Stop" && textField(response, "decision") == "block" {
			decision = "continue"
		}
	} else if event == "PreToolUse" {
		var permission string
		if value, exists := specific["permissionDecision"]; exists && json.Unmarshal(value, &permission) != nil {
			return writeAntigravityResponse(event, "deny", "Hook returned an invalid permission decision.")
		}
		switch permission {
		case "", "allow":
		case "ask":
			decision = "force_ask"
		case "deny":
			decision = "deny"
		default:
			decision = "deny"
			message += "\nUnsupported hook permission decision."
		}
		if string(response["continue"]) == "false" || textField(response, "decision") == "block" {
			decision = "deny"
		}
		if _, exists := specific["updatedInput"]; exists {
			decision = "deny"
			message += "\nCanonical updatedInput cannot be applied to native tool arguments."
		}
	}
	return writeAntigravityResponse(event, decision, message)
}

func writeAntigravityResponse(event, decision, message string) int {
	// Native allow delegates to policy; it must never become auto_approve.
	// https://antigravity.google/docs/hooks#input-and-output-contract
	for {
		response := map[string]any{}
		switch event {
		case "PreToolUse":
			response["decision"] = decision
			response["reason"] = message
		case "Stop", "StopFailure":
			if decision == "deny" {
				decision = "stop"
			}
			response["decision"] = decision
			response["reason"] = message
		case "SessionStart":
			if message != "" {
				response["injectSteps"] = []map[string]string{{"ephemeralMessage": message}}
			}
		default:
			// PostToolUse has no native context-injection response.
			if message != "" {
				fmt.Fprintln(os.Stderr, message)
			}
		}
		encoded, err := encodeJSON(response)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Cannot encode Antigravity hook response:", err)
			return 1
		}
		if len(encoded) <= 64*1024 {
			_, err = os.Stdout.Write(encoded)
			if err != nil {
				return 1
			}
			return 0
		}
		characters := []rune(message)
		message = string(characters[:len(characters)/2]) + "\n[truncated] Additional hook feedback did not fit."
	}
}
