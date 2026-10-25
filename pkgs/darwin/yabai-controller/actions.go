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

type space struct {
	ID         uint64 `json:"id"`
	Index      int    `json:"index"`
	Display    int    `json:"display"`
	Visible    bool   `json:"is-visible"`
	Fullscreen bool   `json:"is-native-fullscreen"`
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

func displaySpaces(ctx context.Context, socket, selector string) ([]space, error) {
	args := []string{"query", "--spaces", "id,index,display,is-native-fullscreen,is-visible", "--display"}
	if selector != "" {
		args = append(args, selector)
	}
	data, err := sendYabai(ctx, socket, args...)
	if err != nil {
		return nil, err
	}
	var spaces []space
	if err := json.Unmarshal(data, &spaces); err != nil {
		return nil, fmt.Errorf("decode display spaces: %w", err)
	}
	return spaces, nil
}

func displaySpace(ctx context.Context, socket string, number int) (space, error) {
	if number < 1 {
		return space{}, fmt.Errorf("space number must be positive")
	}
	spaces, err := displaySpaces(ctx, socket, "")
	if err != nil {
		return space{}, err
	}
	for _, space := range spaces {
		if space.Fullscreen {
			continue
		}
		number--
		if number == 0 && space.Index > 0 {
			return space, nil
		}
	}
	return space{}, fmt.Errorf("requested regular space does not exist on the focused display")
}

func execute(ctx context.Context, socket string, request action) (uint64, error) {
	var args []string
	var targetSpaceID uint64
	switch request.Action {
	case "command":
		args = request.Args
		if len(args) == 3 && args[0] == "display" && args[1] == "--space" && (args[2] == "prev" || args[2] == "next") {
			spaces, err := displaySpaces(ctx, socket, "mouse")
			if err != nil {
				return 0, err
			}
			for index, current := range spaces {
				if !current.Visible {
					continue
				}
				target := index - 1
				if args[2] == "next" {
					target = index + 1
				}
				// Wrap within the current display, including fullscreen Spaces.
				target = (target + len(spaces)) % len(spaces)
				targetSpaceID = spaces[target].ID
				args = []string{"display", strconv.Itoa(spaces[target].Display), "--space", strconv.Itoa(spaces[target].Index)}
				break
			}
		}
	case "focus-space", "move-space":
		var focused window
		if request.Action == "move-space" {
			var err error
			focused, err = focusedWindow(ctx, socket)
			if err != nil {
				return 0, err
			}
		}
		target, err := displaySpace(ctx, socket, request.Space)
		if err != nil {
			return 0, err
		}
		targetSpaceID = target.ID
		if request.Action == "focus-space" {
			args = []string{"space", "--focus", strconv.Itoa(target.Index)}
		} else {
			args = []string{"window", strconv.FormatUint(uint64(focused.ID), 10), "--space", strconv.Itoa(target.Index), "--focus"}
		}
	case "stack-recent":
		focused, err := focusedWindow(ctx, socket)
		if err != nil {
			return 0, err
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
			return 0, err
		}
		args = []string{"window", "--focus", wrap}
	case "toggle-float":
		focused, err := focusedWindow(ctx, socket)
		if err != nil {
			return 0, err
		}
		layer := "above"
		if focused.Floating {
			layer = "below"
		}
		args = []string{"window", strconv.FormatUint(uint64(focused.ID), 10), "--toggle", "float", "--sub-layer", layer}
	default:
		return 0, fmt.Errorf("unknown action %q", request.Action)
	}

	_, err := sendYabai(ctx, socket, args...)
	return targetSpaceID, err
}
