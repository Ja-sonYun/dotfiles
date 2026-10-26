package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"time"
)

func captureLifecycle(input map[string]json.RawMessage) {
	if _, exists := input["reported_at"]; !exists {
		input["reported_at"] = json.RawMessage(strconv.FormatInt(time.Now().UnixMilli(), 10))
	}
	if _, exists := input["event_id"]; !exists {
		var id [16]byte
		if _, err := rand.Read(id[:]); err == nil {
			setText(input, "event_id", hex.EncodeToString(id[:]))
		}
	}
}
