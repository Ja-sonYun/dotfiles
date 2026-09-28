package main

import "encoding/json"

func restoreFailure(data []byte) []byte {
	var response map[string]json.RawMessage
	if json.Unmarshal(data, &response) != nil || response == nil {
		return data
	}
	var specific map[string]json.RawMessage
	if json.Unmarshal(response["hookSpecificOutput"], &specific) != nil || textField(specific, "hookEventName") != "PostToolUse" {
		return data
	}
	setText(specific, "hookEventName", "PostToolUseFailure")
	response["hookSpecificOutput"], _ = encodeJSON(specific)
	encoded, err := encodeJSON(response)
	if err != nil {
		return data
	}
	return encoded
}
