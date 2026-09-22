package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/tiktoken-go/tokenizer"
)

const help = `Usage: jev [options]
       jev [options] --- [options] [--- ...]
       jev models [--timeout 10s]

  --question TEXT           Question for a single-question CLI request
  --state TEXT              State to evaluate
  --choices.KEY TEXT        Choice description
  --score.INDEX TEXT        Score level, numbered consecutively from 0
  --noul                    Evaluate the question as a yes/no proposition
  --noul.true TEXT          Optional description of a yes outcome
  --noul.false TEXT         Optional description of a no outcome
  --questions.ID.FIELD TEXT Named questions using API fields
  --model NAME              Model ID or alias (default: jev-latest)
  --timeout DURATION        HTTP deadline including body reading (default: 10s)
  --batch-items PATH        Split a state array at .items, .nested.items, or .
  --batch-size auto|N       Token-based batching, optionally capped at N items
  --help                    Show this help

Without CLI body options, read one JSON object containing state and questions
from stdin: jev --batch-items .items < request.json
Only state and questions are accepted in this object; pass settings as options.
If any body option is present, provide the complete request through CLI options.
CLI body options and stdin are not merged. Plain-text stdin is not supported.

All input roots accept nested dot paths and --ROOT-json JSON:
question, state, choices, score, noul, questions.
For example: --score.0.description Low --score.1.description High
             --state-json '{"message":"Help"}'
             --questions.status.type choice
             --questions.status.instructions 'Classify this'
             --questions.status.criteria.done 'Work finished'

Dot values are strings. Numeric path components create arrays, except for
question IDs and Choice option keys. Array indices must start at 0 without gaps.
JSON values retain their types. Disjoint paths merge; overlapping values fail.
Use JSON for literal keys containing dots. Named questions cannot be combined
with single-question options. Single-question answers use the ID "result".

Separate independent requests with ---. All requests run concurrently and must
provide their own state and explicit question(s); stdin is unavailable in this mode.
Model and timeout apply only to their request, with no settings inherited.
Use --state=--- to pass a literal separator as a value.
Multiple requests return an input-ordered JSON array of {"response": ...} or
{"error": "..."} entries. Any failed request causes a nonzero exit code.

Authentication: TYPESAFE_API_KEY. No automatic retries.
Output: complete API JSON on stdout; errors on stderr with a nonzero exit code.
Extract values with jq, for example: jq -r '.answers.result.choice'

Batching defaults to auto when --batch-items is provided. Items must have unique
string IDs matching question keys one-to-one. Only independent judgments are
supported; shared state is copied and IDs are never renumbered. Paths traverse
object keys only; array indices, wildcards and escaped dots are not supported.
All batches run concurrently. cl100k_base estimates enforce 48000 tokens for the
whole request and 24000 for state plus the longest question. Estimates add cached
question and envelope counts to each candidate state's count; they can differ
from tokenizing the full JSON and are not the Jev tokenizer. Oversized single
items fail without truncation or retries.
Batch output contains model, merged answers, and ordered original batches.
Usage and other metadata remain in batches. No output filtering is performed.
`

type node struct {
	kind     string
	value    any
	children map[string]*node
}

func jsonNode(value any) *node {
	n := &node{kind: "value", value: value}
	switch value := value.(type) {
	case map[string]any:
		n.kind = "object"
		n.children = make(map[string]*node, len(value))
		for key, child := range value {
			n.children[key] = jsonNode(child)
		}
	case []any:
		n.kind = "array"
		n.children = make(map[string]*node, len(value))
		for i, child := range value {
			n.children[strconv.Itoa(i)] = jsonNode(child)
		}
	}
	return n
}

func merge(left, right *node) (*node, error) {
	if left == nil {
		return right, nil
	}
	if left.kind == "value" || right.kind == "value" {
		return nil, errors.New("duplicate value or conflicting parent/child paths")
	}
	if left.kind != "" && right.kind != "" && left.kind != right.kind {
		return nil, errors.New("cannot merge an object and an array")
	}
	if left.kind == "" {
		left.kind = right.kind
	}
	for key, child := range right.children {
		merged, err := merge(left.children[key], child)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", key, err)
		}
		left.children[key] = merged
	}
	return left, nil
}

func (n *node) materialize(context string) (any, error) {
	if n.kind == "value" {
		return n.value, nil
	}
	kind := n.kind
	if kind == "" {
		kind = "object"
		switch context {
		case "score":
			kind = "array"
		case "choices", "noul", "questions", "named-question":
		default:
			for key := range n.children {
				if _, err := strconv.Atoi(key); err == nil {
					kind = "array"
					break
				}
			}
		}
	}
	object := make(map[string]any, len(n.children))
	for key, child := range n.children {
		childContext := ""
		if context == "questions" {
			childContext = "named-question"
		} else if context == "named-question" && key == "criteria" {
			if questionType := n.children["type"]; questionType != nil {
				childContext, _ = questionType.value.(string)
				if childContext == "choice" {
					childContext = "choices"
				}
			}
		}
		value, err := child.materialize(childContext)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", key, err)
		}
		object[key] = value
	}
	if kind == "object" {
		return object, nil
	}
	array := make([]any, len(object))
	for i := range array {
		value, ok := object[strconv.Itoa(i)]
		if !ok {
			return nil, errors.New("array indices must be consecutive from 0")
		}
		array[i] = value
	}
	return array, nil
}

func parse(args []string) (map[string]any, time.Duration, error) {
	roots := make(map[string]*node)
	settings := make(map[string]string)
	noul := false
	for i := 0; i < len(args); i++ {
		if !strings.HasPrefix(args[i], "--") {
			return nil, 0, fmt.Errorf("expected an option, got %q", args[i])
		}
		name, value, hasValue := strings.Cut(strings.TrimPrefix(args[i], "--"), "=")
		if name == "noul" && !hasValue {
			if noul {
				return nil, 0, errors.New("duplicate --noul")
			}
			noul = true
			continue
		}
		if !hasValue {
			i++
			if i == len(args) || strings.HasPrefix(args[i], "--") {
				return nil, 0, fmt.Errorf("--%s needs a value; use = for values starting with --", name)
			}
			value = args[i]
		}
		if name == "model" || name == "timeout" || name == "batch-items" || name == "batch-size" {
			if _, exists := settings[name]; exists {
				return nil, 0, fmt.Errorf("duplicate --%s", name)
			}
			settings[name] = value
			continue
		}
		isJSON := strings.HasSuffix(name, "-json") && !strings.Contains(name, ".")
		if isJSON {
			name = strings.TrimSuffix(name, "-json")
		}
		path := strings.Split(name, ".")
		switch path[0] {
		case "question", "state", "choices", "score", "noul", "questions":
		default:
			return nil, 0, fmt.Errorf("unknown option --%s", name)
		}
		var input any = value
		if isJSON {
			decoder := json.NewDecoder(strings.NewReader(value))
			decoder.UseNumber()
			if err := decoder.Decode(&input); err != nil {
				return nil, 0, fmt.Errorf("--%s-json: invalid JSON", name)
			}
			var trailing any
			if err := decoder.Decode(&trailing); err != io.EOF {
				return nil, 0, fmt.Errorf("--%s-json: expected one JSON value", name)
			}
		} else if len(path) == 1 && name != "question" && name != "state" {
			return nil, 0, fmt.Errorf("use --%s.KEY or --%s-json", name, name)
		}
		branch := jsonNode(input)
		for j := len(path) - 1; j > 0; j-- {
			if path[j] == "" {
				return nil, 0, errors.New("dot paths cannot contain empty components")
			}
			branch = &node{children: map[string]*node{path[j]: branch}}
		}
		merged, err := merge(roots[path[0]], branch)
		if err != nil {
			return nil, 0, fmt.Errorf("--%s: %w", name, err)
		}
		roots[path[0]] = merged
	}
	if noul && roots["noul"] == nil {
		roots["noul"] = jsonNode(nil)
	}
	values := make(map[string]any, len(roots)+1)
	for key, root := range roots {
		value, err := root.materialize(key)
		if err != nil {
			return nil, 0, fmt.Errorf("--%s: %w", key, err)
		}
		values[key] = value
	}
	if model, ok := settings["model"]; ok {
		if strings.TrimSpace(model) == "" {
			return nil, 0, errors.New("--model cannot be empty")
		}
		values["model"] = model
	}
	timeout := 10 * time.Second
	if value, ok := settings["timeout"]; ok {
		var err error
		timeout, err = time.ParseDuration(value)
		if err != nil || timeout <= 0 {
			return nil, 0, errors.New("--timeout must be a positive duration, such as 2s")
		}
	}
	if path, ok := settings["batch-items"]; ok {
		if path != "." {
			if !strings.HasPrefix(path, ".") {
				return nil, 0, errors.New("--batch-items must be a dot path starting with .")
			}
			for _, key := range strings.Split(path[1:], ".") {
				if key == "" || strings.ContainsAny(key, "[]*\\|()\"' \t\r\n") {
					return nil, 0, errors.New("--batch-items supports nonempty object keys separated by dots only")
				}
			}
		}
		values["batch-items"] = path
	}
	if size, ok := settings["batch-size"]; ok {
		if _, enabled := settings["batch-items"]; !enabled {
			return nil, 0, errors.New("--batch-size requires --batch-items")
		}
		if size != "auto" {
			limit, err := strconv.Atoi(size)
			if err != nil || limit <= 0 {
				return nil, 0, errors.New("--batch-size must be auto or a positive integer")
			}
			values["batch-size"] = limit
		}
	}
	return values, timeout, nil
}

func requestBody(values map[string]any) (map[string]any, error) {
	state, ok := values["state"]
	if !ok {
		return nil, errors.New("--state or --state-json is required")
	}
	questions, batch := values["questions"]
	if batch {
		for _, key := range []string{"question", "choices", "score", "noul"} {
			if _, exists := values[key]; exists {
				return nil, errors.New("named questions cannot be combined with single-question options")
			}
		}
	} else {
		question := make(map[string]any)
		for _, key := range []string{"choices", "score", "noul"} {
			if criteria, exists := values[key]; exists {
				if question["type"] != nil {
					return nil, errors.New("choose exactly one of choices, score, or noul")
				}
				question["type"] = strings.TrimSuffix(key, "s")
				question["criteria"] = criteria
			}
		}
		if question["type"] == nil {
			return nil, errors.New("choose choices, score, or noul")
		}
		instructions, supplied := values["question"]
		if !supplied {
			return nil, errors.New("provide --question or --question-json")
		}
		question["instructions"] = instructions
		questions = map[string]any{"result": question}
	}
	items, ok := questions.(map[string]any)
	if !ok || len(items) == 0 {
		return nil, errors.New("questions must be a nonempty object")
	}
	for id, item := range items {
		question, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("question %q must be an object", id)
		}
		switch question["type"] {
		case "choice":
			criteria, ok := question["criteria"].(map[string]any)
			if !ok || len(criteria) == 0 {
				return nil, fmt.Errorf("question %q needs a nonempty Choice object", id)
			}
		case "score":
			criteria, ok := question["criteria"].([]any)
			if !ok || len(criteria) < 2 {
				return nil, fmt.Errorf("question %q needs at least two Score levels", id)
			}
		case "noul":
			if criteria := question["criteria"]; criteria != nil {
				object, ok := criteria.(map[string]any)
				if !ok {
					return nil, fmt.Errorf("question %q needs a Noul criteria object", id)
				}
				for key := range object {
					if key != "true" && key != "false" {
						return nil, fmt.Errorf("question %q: Noul criteria keys must be true or false", id)
					}
				}
			}
		default:
			return nil, fmt.Errorf("question %q needs type choice, score, or noul", id)
		}
	}
	model, ok := values["model"]
	if !ok {
		model = "jev-latest"
	}
	return map[string]any{
		"model":     model,
		"state":     state,
		"questions": questions,
	}, nil
}

func validateResponse(data []byte, payload map[string]any) error {
	var response struct {
		Models  json.RawMessage            `json:"models"`
		Answers map[string]json.RawMessage `json:"answers"`
	}
	if err := json.Unmarshal(data, &response); err != nil {
		return errors.New("Jev API returned an invalid JSON response")
	}
	if payload == nil {
		var models []json.RawMessage
		if err := json.Unmarshal(response.Models, &models); err != nil || models == nil {
			return errors.New("Jev response is missing a models array")
		}
		return nil
	}
	questions := payload["questions"].(map[string]any)
	for id, item := range questions {
		var answer struct {
			Type   string   `json:"type"`
			Choice *string  `json:"choice"`
			Score  *float64 `json:"score"`
			Noul   *float64 `json:"noul"`
		}
		if err := json.Unmarshal(response.Answers[id], &answer); err != nil {
			return fmt.Errorf("Jev response has a missing or invalid answer for %q", id)
		}
		question := item.(map[string]any)
		if answer.Type != question["type"] {
			return fmt.Errorf("Jev response has an incorrect answer type for %q", id)
		}
		switch answer.Type {
		case "choice":
			if answer.Choice != nil {
				if _, ok := question["criteria"].(map[string]any)[*answer.Choice]; ok {
					continue
				}
			}
		case "score":
			if answer.Score != nil && *answer.Score >= 0 && *answer.Score <= float64(len(question["criteria"].([]any))-1) {
				continue
			}
		case "noul":
			if answer.Noul != nil && *answer.Noul >= 0 && *answer.Noul <= 1 {
				continue
			}
		}
		return fmt.Errorf("Jev response has an invalid value for %q", id)
	}
	return nil
}

func run(args []string) error {
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		_, err := fmt.Fprint(os.Stdout, help)
		return err
	}
	groups := [][]string{{}}
	for _, arg := range args {
		if arg == "---" {
			groups = append(groups, []string{})
		} else {
			groups[len(groups)-1] = append(groups[len(groups)-1], arg)
		}
	}
	if len(groups) > 1 {
		return runRequests(groups)
	}
	models := len(args) > 0 && args[0] == "models"
	if models {
		args = args[1:]
	}
	values, timeout, err := parse(args)
	if err != nil {
		return err
	}
	var payload map[string]any
	if models {
		if len(values) != 0 {
			return errors.New("models accepts only --timeout")
		}
	} else {
		cliBody := false
		for _, key := range []string{"state", "question", "questions", "choices", "score", "noul"} {
			if _, exists := values[key]; exists {
				cliBody = true
				break
			}
		}
		if !cliBody {
			info, err := os.Stdin.Stat()
			if err != nil {
				return err
			}
			if info.Mode()&os.ModeCharDevice != 0 {
				return errors.New("provide a JSON object with state and questions on stdin, or a complete CLI request")
			}
			var body map[string]any
			decoder := json.NewDecoder(os.Stdin)
			decoder.UseNumber()
			if err := decoder.Decode(&body); err != nil {
				return fmt.Errorf("stdin JSON: %w", err)
			}
			if err := decoder.Decode(new(any)); err != io.EOF {
				return errors.New("stdin must contain exactly one JSON object")
			}
			for key := range body {
				if key != "state" && key != "questions" {
					return fmt.Errorf("stdin JSON: unsupported field %q; only state and questions are accepted", key)
				}
			}
			for _, key := range []string{"state", "questions"} {
				value, exists := body[key]
				if !exists {
					return fmt.Errorf("stdin JSON: %s is required", key)
				}
				values[key] = value
			}
		}
		payload, err = requestBody(values)
		if err != nil {
			return err
		}
	}
	batches, err := prepareBatches(payload, values)
	if err != nil {
		return err
	}
	_, batched := values["batch-items"]
	data, err := executeBatches(batches, timeout, batched)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(os.Stdout, string(bytes.TrimSpace(data)))
	return err
}

func runRequests(groups [][]string) error {
	plans := make([][]requestBatch, len(groups))
	batched := make([]bool, len(groups))
	timeouts := make([]time.Duration, len(groups))
	for i, args := range groups {
		if len(args) == 0 {
			return fmt.Errorf("request %d: empty request", i+1)
		}
		values, timeout, err := parse(args)
		if err != nil {
			return fmt.Errorf("request %d: %w", i+1, err)
		}
		_, question := values["question"]
		_, questions := values["questions"]
		if !question && !questions {
			return fmt.Errorf("request %d: multiple requests require explicit questions; stdin is unavailable", i+1)
		}
		payload, err := requestBody(values)
		if err != nil {
			return fmt.Errorf("request %d: %w", i+1, err)
		}
		plans[i], err = prepareBatches(payload, values)
		if err != nil {
			return fmt.Errorf("request %d: %w", i+1, err)
		}
		_, batched[i] = values["batch-items"]
		timeouts[i] = timeout
	}

	results := make([]struct {
		Response json.RawMessage `json:"response,omitempty"`
		Error    string          `json:"error,omitempty"`
	}, len(groups))
	var pending sync.WaitGroup
	for i := range groups {
		pending.Add(1)
		go func(i int) {
			defer pending.Done()
			data, err := executeBatches(plans[i], timeouts[i], batched[i])
			if err != nil {
				results[i].Error = err.Error()
				return
			}
			results[i].Response = data
		}(i)
	}
	pending.Wait()

	if err := json.NewEncoder(os.Stdout).Encode(results); err != nil {
		return err
	}
	var failures []error
	for i, result := range results {
		if result.Error != "" {
			failures = append(failures, fmt.Errorf("request %d: %s", i+1, result.Error))
		}
	}
	return errors.Join(failures...)
}

const (
	batchTokenBudget    = 48000
	questionTokenBudget = 24000
)

type requestBatch struct {
	payload        map[string]any
	first          int
	last           int
	tokens         int
	questionTokens int
}

func replaceBatchItems(state any, path []string, items []any) any {
	if len(path) == 0 {
		return items
	}
	object := maps.Clone(state.(map[string]any))
	object[path[0]] = replaceBatchItems(object[path[0]], path[1:], items)
	return object
}

func countTokens(codec tokenizer.Codec, value any) (int, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return 0, err
	}
	ids, _, err := codec.Encode(string(data))
	return len(ids), err
}

func prepareBatches(payload, values map[string]any) ([]requestBatch, error) {
	selector, enabled := values["batch-items"].(string)
	if !enabled {
		return []requestBatch{{payload: payload}}, nil
	}
	var path []string
	if selector != "." {
		path = strings.Split(selector[1:], ".")
	}
	selected := payload["state"]
	for _, key := range path {
		object, ok := selected.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("--batch-items %s: cannot traverse non-object at %q", selector, key)
		}
		selected, ok = object[key]
		if !ok {
			return nil, fmt.Errorf("--batch-items %s: missing key %q", selector, key)
		}
	}
	items, ok := selected.([]any)
	if !ok || len(items) == 0 {
		return nil, errors.New("--batch-items must select a nonempty array")
	}
	questions := payload["questions"].(map[string]any)
	ids := make([]string, len(items))
	seen := make(map[string]bool, len(items))
	for i, value := range items {
		item, ok := value.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("batch item %d must be an object with a string id", i+1)
		}
		id, ok := item["id"].(string)
		if !ok {
			return nil, fmt.Errorf("batch item %d must have a string id", i+1)
		}
		if seen[id] {
			return nil, fmt.Errorf("duplicate batch item id %q", id)
		}
		if _, exists := questions[id]; !exists {
			return nil, fmt.Errorf("batch item %q has no matching question", id)
		}
		seen[id] = true
		ids[i] = id
	}
	if len(seen) != len(questions) {
		return nil, errors.New("every question must match exactly one batch item id")
	}
	codec, err := tokenizer.Get(tokenizer.Cl100kBase)
	if err != nil {
		return nil, err
	}
	questionCounts := make([]int, len(ids))
	for i, id := range ids {
		questionCounts[i], err = countTokens(codec, map[string]any{id: questions[id]})
		if err != nil {
			return nil, err
		}
	}
	envelope := maps.Clone(payload)
	envelope["state"] = nil
	envelope["questions"] = map[string]any{}
	fixedTokens, err := countTokens(codec, envelope)
	if err != nil {
		return nil, err
	}
	limit, _ := values["batch-size"].(int)
	if limit == 0 {
		limit = len(items)
	}

	var batches []requestBatch
	for first := 0; first < len(items); {
		var accepted requestBatch
		low, high := 1, min(limit, len(items)-first)
		for low <= high {
			size := low + (high-low)/2
			last := first + size - 1
			batchQuestions := make(map[string]any, size)
			questionSum, longestQuestion := 0, 0
			for i := first; i <= last; i++ {
				batchQuestions[ids[i]] = questions[ids[i]]
				questionSum += questionCounts[i]
				longestQuestion = max(longestQuestion, questionCounts[i])
			}
			candidate := maps.Clone(payload)
			candidate["state"] = replaceBatchItems(payload["state"], path, items[first:last+1])
			candidate["questions"] = batchQuestions
			stateTokens, err := countTokens(codec, candidate["state"])
			if err != nil {
				return nil, err
			}
			tokens := fixedTokens + stateTokens + questionSum
			longest := fixedTokens + stateTokens + longestQuestion
			if tokens > batchTokenBudget || longest > questionTokenBudget {
				if last == first {
					return nil, fmt.Errorf("batch item %q exceeds estimated token budgets: request %d/%d, state plus question %d/%d",
						ids[last], tokens, batchTokenBudget, longest, questionTokenBudget)
				}
				high = size - 1
				continue
			}
			accepted = requestBatch{
				payload:        candidate,
				first:          first,
				last:           last,
				tokens:         tokens,
				questionTokens: longest,
			}
			low = size + 1
		}
		batches = append(batches, accepted)
		first = accepted.last + 1
	}
	return batches, nil
}

func executeBatches(batches []requestBatch, timeout time.Duration, batched bool) ([]byte, error) {
	if !batched {
		return sendRequest(batches[0].payload, timeout)
	}
	responses := make([]json.RawMessage, len(batches))
	failures := make([]error, len(batches))
	var pending sync.WaitGroup
	for i, batch := range batches {
		pending.Add(1)
		go func(i int, batch requestBatch) {
			defer pending.Done()
			data, err := sendRequest(batch.payload, timeout)
			if err != nil {
				failures[i] = fmt.Errorf("batch %d (items %d-%d; estimated request tokens %d, state plus question %d): %w",
					i+1, batch.first+1, batch.last+1, batch.tokens, batch.questionTokens, err)
				return
			}
			responses[i] = data
		}(i, batch)
	}
	pending.Wait()
	if err := errors.Join(failures...); err != nil {
		return nil, err
	}

	merged := struct {
		Model   string                     `json:"model"`
		Answers map[string]json.RawMessage `json:"answers"`
		Batches []json.RawMessage          `json:"batches"`
	}{Answers: make(map[string]json.RawMessage), Batches: responses}
	for i, data := range responses {
		var response struct {
			Model   string                     `json:"model"`
			Answers map[string]json.RawMessage `json:"answers"`
		}
		if err := json.Unmarshal(data, &response); err != nil {
			return nil, fmt.Errorf("batch %d: %w", i+1, err)
		}
		if response.Model == "" {
			return nil, fmt.Errorf("batch %d: response is missing a model", i+1)
		}
		if i == 0 {
			merged.Model = response.Model
		} else if merged.Model != response.Model {
			return nil, fmt.Errorf("batch %d: model %q differs from %q", i+1, response.Model, merged.Model)
		}
		for id := range batches[i].payload["questions"].(map[string]any) {
			merged.Answers[id] = response.Answers[id]
		}
	}
	return json.Marshal(merged)
}

func sendRequest(payload map[string]any, timeout time.Duration) ([]byte, error) {
	method, endpoint := http.MethodGet, "/v1/models"
	var body []byte
	if payload != nil {
		var err error
		body, err = json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		method, endpoint = http.MethodPost, "/v1/systemone"
	}
	key := os.Getenv("TYPESAFE_API_KEY")
	if strings.TrimSpace(key) == "" {
		return nil, errors.New("TYPESAFE_API_KEY is not set")
	}
	request, err := http.NewRequest(method, "https://api.typesafe.ai"+endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+key)
	request.Header.Set("Content-Type", "application/json")
	client := &http.Client{
		Timeout: timeout,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("Jev request failed: %w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, fmt.Errorf("reading Jev response (HTTP %d): %w", response.StatusCode, err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("Jev API returned HTTP %d\n%s", response.StatusCode, data)
	}
	if err := validateResponse(data, payload); err != nil {
		return nil, err
	}
	return data, nil
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "jev:", err)
		os.Exit(1)
	}
}
