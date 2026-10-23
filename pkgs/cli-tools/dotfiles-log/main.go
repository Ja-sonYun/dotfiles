package main

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	logclient "dotfiles-log/clients/go"
)

//go:embed config.json
var configuration []byte

const maxFrame = logclient.MaxFrame

type settings struct {
	File       string `json:"file"`
	SocketPath string `json:"socketPath"`
	MaxBytes   int    `json:"maxBytes"`
	Level      string `json:"level"`
}

type record struct {
	Time      string            `json:"time"`
	Component string            `json:"component"`
	Level     string            `json:"level"`
	Event     string            `json:"event"`
	PID       int               `json:"pid"`
	Fields    map[string]string `json:"fields,omitempty"`
	Excerpt   string            `json:"fields_excerpt,omitempty"`
	Truncated bool              `json:"truncated,omitempty"`
}

var levels = map[string]int{"debug": 10, "info": 20, "warning": 30, "error": 40}

func encode(entry record) []byte {
	data, _ := json.Marshal(entry)
	return append(data, '\n')
}

func bounded(entry record, maximum int) []byte {
	if len(entry.Component) > 64 {
		entry.Component = entry.Component[:64]
		entry.Truncated = true
	}
	if len(entry.Event) > 64 {
		entry.Event = entry.Event[:64]
		entry.Truncated = true
	}
	data := encode(entry)
	if len(data) <= maximum {
		return data
	}

	details, _ := json.Marshal(entry.Fields)
	entry.Fields = nil
	entry.Truncated = true
	low, high := 0, len(details)
	for low < high {
		middle := (low + high + 1) / 2
		entry.Excerpt = string(details[:middle])
		if len(encode(entry)) <= maximum {
			low = middle
		} else {
			high = middle - 1
		}
	}
	entry.Excerpt = string(details[:low])
	return encode(entry)
}

func send(path string, entry record) error {
	var client logclient.Client
	client.Send(path, logclient.Record{
		Time:      entry.Time,
		Component: entry.Component,
		Level:     entry.Level,
		Event:     entry.Event,
		PID:       entry.PID,
		Fields:    entry.Fields,
	})
	return nil
}

func run() error {
	var cfg settings
	if err := json.Unmarshal(configuration, &cfg); err != nil {
		return err
	}
	if cfg.MaxBytes < 1024 || levels[cfg.Level] == 0 || len(cfg.SocketPath) > 103 {
		return errors.New("invalid logger configuration")
	}
	if len(os.Args) == 2 {
		switch os.Args[1] {
		case "serve":
			return serve(cfg)
		case "cleanup":
			return cleanup(cfg.SocketPath)
		}
	}
	if len(os.Args) < 4 {
		return errors.New("usage: dotfiles-log serve | COMPONENT LEVEL EVENT [KEY=VALUE ...]")
	}
	severity, valid := levels[os.Args[2]]
	if !valid {
		return errors.New("invalid severity")
	}
	if severity < levels[cfg.Level] {
		return nil
	}
	entry := record{
		Time:      time.Now().UTC().Format(time.RFC3339Nano),
		Component: os.Args[1],
		Level:     os.Args[2],
		Event:     os.Args[3],
		PID:       os.Getppid(),
		Fields:    make(map[string]string),
	}
	for _, argument := range os.Args[4:] {
		key, value, ok := strings.Cut(argument, "=")
		if !ok {
			return errors.New("fields must use KEY=VALUE")
		}
		entry.Fields[key] = value
	}
	return send(cfg.SocketPath, entry)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "dotfiles-log:", err)
		os.Exit(1)
	}
}
