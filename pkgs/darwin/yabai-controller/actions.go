package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
)

type action struct {
	Action string   `json:"action"`
	Args   []string `json:"args"`
	Space  int      `json:"space"`
}

type window struct {
	ID       uint32 `json:"id"`
	Floating bool   `json:"is-floating"`
}

func focusedWindow(ctx context.Context, socket string) (window, error) {
	data, err := sendYabai(ctx, socket, "query", "--windows", "id,is-floating", "--window")
	if err != nil {
		return window{}, err
	}
	var focused window
	if err := json.Unmarshal(data, &focused); err != nil {
		return window{}, fmt.Errorf("decode focused window: %w", err)
	}
	if focused.ID == 0 {
		return window{}, fmt.Errorf("no focused window")
	}
	return focused, nil
}

func displaySpace(ctx context.Context, socket string, number int) (string, error) {
	if number < 1 {
		return "", fmt.Errorf("space number must be positive")
	}
	data, err := sendYabai(ctx, socket, "query", "--spaces", "index,is-native-fullscreen", "--display")
	if err != nil {
		return "", err
	}
	var spaces []struct {
		Index      int  `json:"index"`
		Fullscreen bool `json:"is-native-fullscreen"`
	}
	if err := json.Unmarshal(data, &spaces); err != nil {
		return "", fmt.Errorf("decode display spaces: %w", err)
	}
	for _, space := range spaces {
		if space.Fullscreen {
			continue
		}
		number--
		if number == 0 && space.Index > 0 {
			return strconv.Itoa(space.Index), nil
		}
	}
	return "", fmt.Errorf("requested regular space does not exist on the focused display")
}

func execute(ctx context.Context, socket string, request action) error {
	var args []string
	switch request.Action {
	case "command":
		args = request.Args
	case "focus-space", "move-space":
		var focused window
		if request.Action == "move-space" {
			var err error
			focused, err = focusedWindow(ctx, socket)
			if err != nil {
				return err
			}
		}
		target, err := displaySpace(ctx, socket, request.Space)
		if err != nil {
			return err
		}
		if request.Action == "focus-space" {
			args = []string{"space", "--focus", target}
		} else {
			args = []string{"window", strconv.FormatUint(uint64(focused.ID), 10), "--space", target, "--focus"}
		}
	case "stack-recent":
		focused, err := focusedWindow(ctx, socket)
		if err != nil {
			return err
		}
		args = []string{"window", "recent", "--stack", strconv.FormatUint(uint64(focused.ID), 10)}
	case "focus-stack-prev", "focus-stack-next":
		direction, wrap := "stack.prev", "stack.last"
		if request.Action == "focus-stack-next" {
			direction, wrap = "stack.next", "stack.first"
		}
		_, err := sendYabai(ctx, socket, "window", "--focus", direction)
		var rejected yabaiError
		if !errors.As(err, &rejected) {
			return err
		}
		args = []string{"window", "--focus", wrap}
	case "toggle-float":
		focused, err := focusedWindow(ctx, socket)
		if err != nil {
			return err
		}
		layer := "above"
		if focused.Floating {
			layer = "below"
		}
		args = []string{"window", strconv.FormatUint(uint64(focused.ID), 10), "--toggle", "float", "--sub-layer", layer}
	default:
		return fmt.Errorf("unknown action %q", request.Action)
	}

	_, err := sendYabai(ctx, socket, args...)
	return err
}
