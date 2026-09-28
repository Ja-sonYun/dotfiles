package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
)

func main() {
	os.Exit(run())
}

func run() int {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Expected codex or post-tool-failure.")
		return 2
	}
	if os.Args[1] != "codex" && os.Args[1] != "post-tool-failure" {
		fmt.Fprintln(os.Stderr, "Unknown hook adapter.")
		return 2
	}
	options := flag.NewFlagSet(os.Args[1], flag.ContinueOnError)
	timeout := options.Int("timeout", 0, "Execution timeout in seconds")
	event := options.String("event", "", "Event override")
	notification := options.String("notification-type", "", "Notification type")
	if err := options.Parse(os.Args[2:]); err != nil {
		return 2
	}
	if options.NArg() != 1 || *timeout < 0 || (os.Args[1] == "codex" && *timeout == 0) {
		fmt.Fprintln(os.Stderr, "Expected a command and a valid timeout.")
		return 2
	}
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cannot read hook input:", err)
		return 1
	}
	if len(bytes.TrimSpace(data)) == 0 {
		data = []byte("{}")
	}
	var input map[string]json.RawMessage
	err = json.Unmarshal(data, &input)
	failure := os.Args[1] == "post-tool-failure"
	if failure && (err != nil || input == nil) {
		fmt.Fprintln(os.Stderr, "Invalid post-tool hook input: expected a JSON object.")
		return 1
	}
	if err != nil || input == nil {
		input = make(map[string]json.RawMessage)
	}
	if failure {
		input["hook_event_name"] = json.RawMessage(`"PostToolUse"`)
		input["tool_failed"] = json.RawMessage("true")
	} else {
		input = translateCodex(input, *event, *notification)
	}
	data, err = encodeJSON(input)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cannot encode hook input:", err)
		return 1
	}
	return runCommand(options.Arg(0), data, *timeout, failure)
}

func encodeJSON(value any) ([]byte, error) {
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func textField(input map[string]json.RawMessage, name string) string {
	var value string
	_ = json.Unmarshal(input[name], &value)
	return value
}

func setText(input map[string]json.RawMessage, name, value string) {
	input[name], _ = json.Marshal(value)
}
