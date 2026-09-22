package main

import (
	"sort"
	"strings"

	"github.com/betterleaks/betterleaks/detect"
)

type redactor struct {
	detector    *detect.Detector
	rules       []rule
	commonRules []rule
}

type match struct {
	start    int
	end      int
	kind     string
	priority int
}

func (r *redactor) detected(input string) []rule {
	var rules []rule
	seen := make(map[string]bool)
	add := func(kind, secret string) {
		key := kind + "\x00" + secret
		if secret != "" && !seen[key] {
			seen[key] = true
			rules = append(rules, rule{kind: kind, literal: secret})
		}
	}
	for _, finding := range r.detector.DetectString(input) {
		add(finding.RuleID, finding.Secret)
		for _, set := range finding.ComponentSets {
			for _, component := range set.Components {
				add(component.RuleID, component.Secret)
			}
		}
	}
	return rules
}

func (r *redactor) mask(input string) string {
	var matches []match
	add := func(start, end int, kind string) {
		if end > start {
			matches = append(matches, match{start, end, kind, len(matches)})
		}
	}
	for _, rules := range [][]rule{r.rules, r.detected(input), r.commonRules} {
		for _, rule := range rules {
			if rule.pattern != nil {
				for _, loc := range rule.pattern.FindAllStringSubmatchIndex(input, -1) {
					if len(loc) > 2 {
						add(loc[2], loc[3], rule.kind)
					} else {
						add(loc[0], loc[1], rule.kind)
					}
				}
				continue
			}
			for offset := 0; offset < len(input); {
				index := strings.Index(input[offset:], rule.literal)
				if index < 0 {
					break
				}
				start := offset + index
				add(start, start+len(rule.literal), rule.kind)
				offset = start + 1
			}
		}
	}
	sort.SliceStable(matches, func(i, j int) bool {
		return matches[i].start < matches[j].start
	})
	var result strings.Builder
	previous := 0
	for i := 0; i < len(matches); {
		best := matches[i]
		start, end := best.start, best.end
		i++
		for i < len(matches) && matches[i].start < end {
			next := matches[i]
			end = max(end, next.end)
			length, bestLength := next.end-next.start, best.end-best.start
			if length > bestLength || (length == bestLength && next.priority < best.priority) {
				best = next
			}
			i++
		}
		result.WriteString(input[previous:start])
		for index, part := range strings.Split(input[start:end], "\x00") {
			if index > 0 {
				result.WriteByte(0)
			}
			if part != "" {
				result.WriteString("[REDACTED:" + best.kind + "]")
			}
		}
		previous = end
	}
	result.WriteString(input[previous:])
	return result.String()
}

func (r *redactor) arguments(args []string) []string {
	if len(args) == 0 {
		return args
	}
	return strings.Split(r.mask(strings.Join(args, "\x00")), "\x00")
}
