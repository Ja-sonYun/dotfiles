package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

type request struct {
	ID      uint64 `json:"id"`
	Payload action `json:"payload"`
}

type response struct {
	ID    uint64 `json:"id"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type job struct {
	request request
	result  chan response
}

func listen(socket string) (*net.UnixListener, error) {
	if err := os.MkdirAll(filepath.Dir(socket), 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(filepath.Dir(socket), 0700); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(socket); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("refusing to replace non-socket path %s", socket)
		}
		conn, err := net.DialTimeout("unix", socket, time.Second)
		if err == nil {
			conn.Close()
			return nil, fmt.Errorf("controller is already listening on %s", socket)
		}
		if !errors.Is(err, syscall.ECONNREFUSED) {
			return nil, err
		}
		if err := os.Remove(socket); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(socket, 0600); err != nil {
		listener.Close()
		return nil, err
	}
	return listener, nil
}

func serveConnection(ctx context.Context, conn net.Conn, jobs chan<- job) {
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	scanner := bufio.NewScanner(conn)
	encoder := json.NewEncoder(conn)
	for scanner.Scan() {
		var input request
		output := response{}
		if err := json.Unmarshal(scanner.Bytes(), &input); err != nil {
			output.Error = fmt.Sprintf("invalid request: %v", err)
		} else if input.ID == 0 {
			output.Error = "request id must be positive"
		} else {
			pending := job{request: input, result: make(chan response, 1)}
			select {
			case jobs <- pending:
			case <-ctx.Done():
				return
			}
			select {
			case output = <-pending.result:
			case <-ctx.Done():
				return
			}
		}
		output.ID = input.ID
		if err := conn.SetWriteDeadline(time.Now().Add(time.Second)); err != nil {
			return
		}
		if err := encoder.Encode(output); err != nil {
			return
		}
	}
	if err := scanner.Err(); err != nil && ctx.Err() == nil {
		log.Printf("read controller request: %v", err)
	}
}

func run(ctx context.Context, socket, yabaiSocket string) error {
	listener, err := listen(socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	stop := context.AfterFunc(ctx, func() { listener.Close() })
	defer stop()

	jobs := make(chan job)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case pending := <-jobs:
				actionContext, cancel := context.WithTimeout(ctx, 10*time.Second)
				err := execute(actionContext, yabaiSocket, pending.request.Payload)
				cancel()
				output := response{ID: pending.request.ID, OK: err == nil}
				if err != nil {
					output.Error = err.Error()
				}
				pending.result <- output
			}
		}
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go serveConnection(ctx, conn, jobs)
	}
}

func main() {
	socket := flag.String("socket", "", "Controller Unix socket path")
	yabaiSocket := flag.String("yabai-socket", "", "Yabai Unix socket path")
	flag.Parse()
	if !filepath.IsAbs(*socket) || !filepath.IsAbs(*yabaiSocket) {
		log.Fatal("--socket and --yabai-socket must be absolute paths")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, *socket, *yabaiSocket); err != nil {
		log.Fatal(err)
	}
}
