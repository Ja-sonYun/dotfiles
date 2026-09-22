package main

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
)

type rule struct {
	kind    string
	literal string
	pattern *regexp.Regexp
}

var envReference = regexp.MustCompile(`^\$\(([A-Za-z_][A-Za-z0-9_]*)\)$`)
var commonRuleType = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*$`)

func loadCommonRules(path string) ([]rule, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("cannot read common rules file")
	}

	var rules []rule
	for i, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if line == "" {
			continue
		}
		kind, pattern, found := strings.Cut(line, ":")
		if !found || !commonRuleType.MatchString(kind) {
			return nil, fmt.Errorf("invalid common rule at line %d; expected type:regex", i+1)
		}
		compiled, err := regexp.Compile(pattern)
		if err != nil || compiled.MatchString("") {
			return nil, fmt.Errorf("invalid or empty-matching regex at common rule line %d", i+1)
		}
		rules = append(rules, rule{kind: kind, pattern: compiled})
	}
	return rules, nil
}

func loadRules(path string, explicit bool) ([]rule, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if !explicit && errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, errors.New("cannot read rules file")
	}

	var rules []rule
	for i, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if line == "" {
			continue
		}

		r := rule{kind: "custom-text", literal: line}
		switch {
		case strings.HasPrefix(line, "text:"):
			r.literal = strings.TrimPrefix(line, "text:")
		case strings.HasPrefix(line, "regex:"):
			r.kind = "custom-regex"
			r.literal = ""
			r.pattern, err = regexp.Compile(strings.TrimPrefix(line, "regex:"))
			if err != nil || r.pattern.MatchString("") {
				return nil, fmt.Errorf("invalid or empty-matching regex at rule line %d", i+1)
			}
		default:
			if match := envReference.FindStringSubmatch(line); match != nil {
				r.kind = "env-" + strings.ReplaceAll(strings.ToLower(match[1]), "_", "-")
				r.literal = os.Getenv(match[1])
			}
		}
		if r.literal != "" || r.pattern != nil {
			rules = append(rules, r)
		}
	}
	return rules, nil
}
