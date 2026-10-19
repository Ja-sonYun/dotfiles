package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
)

type yabaiError string

func (e yabaiError) Error() string {
	return string(e)
}

func sendYabai(ctx context.Context, socket string, args ...string) ([]byte, error) {
	if len(args) == 0 {
		return nil, fmt.Errorf("empty yabai command")
	}
	for _, arg := range args {
		if strings.ContainsRune(arg, 0) {
			return nil, fmt.Errorf("yabai argument contains NUL")
		}
	}

	// Match the pinned client's native int header and double-NUL termination.
	// https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/yabai.c
	payload := strings.Join(args, "\x00") + "\x00\x00"
	frame := make([]byte, 4+len(payload))
	binary.NativeEndian.PutUint32(frame, uint32(len(payload)))
	copy(frame[4:], payload)

	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", socket)
	if err != nil {
		return nil, fmt.Errorf("connect to yabai: %w", err)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	if deadline, ok := ctx.Deadline(); ok {
		if err := conn.SetDeadline(deadline); err != nil {
			return nil, err
		}
	}

	// Send the header and body together because yabai reads the header once.
	for len(frame) > 0 {
		n, err := conn.Write(frame)
		if err != nil {
			return nil, fmt.Errorf("write to yabai; execution may be incomplete: %w", err)
		}
		if n == 0 {
			return nil, io.ErrShortWrite
		}
		frame = frame[n:]
	}
	if err := conn.(*net.UnixConn).CloseWrite(); err != nil {
		return nil, fmt.Errorf("finish yabai request; execution is unknown: %w", err)
	}

	response, err := io.ReadAll(conn)
	if err != nil {
		return response, fmt.Errorf("read from yabai; execution is unknown: %w", err)
	}
	if len(response) > 0 && response[0] == 0x07 {
		return nil, yabaiError(strings.TrimSpace(string(response[1:])))
	}
	return response, nil
}
