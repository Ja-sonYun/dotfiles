package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(arguments []string) int {
	started := time.Now()
	options := flag.NewFlagSet("ai-agent-rules-client", flag.ContinueOnError)
	server := options.String("server", "", "Server executable")
	cacheName := options.String("cache-name", "", "Server directory relative to the user cache")
	timeout := options.Int("timeout", 0, "Request timeout in seconds")
	if options.Parse(arguments) != nil || *server == "" || *cacheName == "" || *timeout <= 0 {
		return 2
	}
	ctx, cancel := context.WithDeadline(context.Background(), started.Add(time.Duration(*timeout+3)*time.Second))
	defer cancel()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)
	var received atomic.Int32
	go func() {
		select {
		case signum := <-signals:
			received.Store(int32(signum.(syscall.Signal)))
			cancel()
		case <-ctx.Done():
		}
	}()
	status, err := exchange(ctx, started, *timeout, *server, *cacheName, options.Args())
	if received.Load() != 0 {
		return 128 + int(received.Load())
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "[Rules not checked] Rules server request failed; continuing:", err)
		return 0
	}
	return status
}

func exchange(ctx context.Context, started time.Time, timeout int, server, cacheName string, serverArgs []string) (int, error) {
	input, err := io.ReadAll(io.LimitReader(os.Stdin, 16*1024*1024+1))
	if err != nil || len(input) > 16*1024*1024 {
		return 0, errors.New("cannot read bounded hook input")
	}
	var payload map[string]json.RawMessage
	if json.Unmarshal(input, &payload) != nil || payload == nil {
		return 0, errors.New("invalid hook input")
	}
	client := os.Getenv("AI_AGENT_CLIENT")
	session := textField(payload, "session_id")
	if session == "" || (client != "Codex" && client != "Claude" && client != "Pi") {
		return 0, errors.New("missing client or session")
	}
	cache := os.Getenv("XDG_CACHE_HOME")
	if cache == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return 0, err
		}
		cache = filepath.Join(home, ".cache")
	}
	configuration := fmt.Sprintf("%x", sha256.Sum256([]byte(server+"\x00"+strings.Join(serverArgs, "\x00"))))
	directory := filepath.Join(cache, cacheName, "shared")
	event := textField(payload, "hook_event_name")
	if event != "SessionStart" && event != "PreToolUse" && event != "PostToolUse" && event != "SessionEnd" {
		return 0, errors.New("unsupported rules hook event")
	}
	environment := make(map[string]string)
	for _, entry := range os.Environ() {
		name, value, _ := strings.Cut(entry, "=")
		environment[name] = value
	}
	request := struct {
		Input         json.RawMessage   `json:"input"`
		Environment   map[string]string `json:"environment"`
		Client        string            `json:"client"`
		PID           int               `json:"pid"`
		Started       float64           `json:"started"`
		Timeout       int               `json:"timeout"`
		Configuration string            `json:"configuration"`
		RegisterOnly  bool              `json:"register_only"`
	}{input, environment, client, os.Getpid(), float64(started.UnixNano()) / 1e9, timeout, configuration, event != "SessionEnd"}
	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	registrationContext, cancelRegistration := context.WithDeadline(ctx, started.Add(time.Duration(timeout)*time.Second))
	defer cancelRegistration()
	for {
		request.RegisterOnly = event != "SessionEnd"
		encoded.Reset()
		if err := encoder.Encode(request); err != nil {
			return 0, err
		}
		for request.RegisterOnly {
			connection, err := (&net.Dialer{}).DialContext(registrationContext, "unix", filepath.Join(directory, "server.sock"))
			if err != nil {
				if !errors.Is(err, syscall.ENOENT) && !errors.Is(err, syscall.ECONNREFUSED) {
					return 0, err
				}
				connection, err = startServer(registrationContext, directory, server, serverArgs, configuration)
				if err != nil && !errors.Is(err, errStartupRace) {
					return 0, err
				}
			}
			if err == nil {
				var response serverResponse
				response, err = sendRequest(registrationContext, connection, encoded.Bytes())
				if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, syscall.ECONNRESET) && !errors.Is(err, syscall.EPIPE) {
					return 0, err
				}
				if err == nil {
					if response.Registered {
						break
					}
					if !response.RetryRegistration {
						return 0, errors.New("rules session registration failed")
					}
				}
			}
			select {
			case <-registrationContext.Done():
				return 0, registrationContext.Err()
			case <-time.After(20 * time.Millisecond):
			}
		}

		request.RegisterOnly = false
		encoded.Reset()
		if err := encoder.Encode(request); err != nil {
			return 0, err
		}
		connection, err := (&net.Dialer{}).DialContext(ctx, "unix", filepath.Join(directory, "server.sock"))
		if err != nil {
			if !errors.Is(err, syscall.ENOENT) && !errors.Is(err, syscall.ECONNREFUSED) {
				return 0, err
			}
			if event == "SessionEnd" {
				return 0, nil
			}
		} else {
			response, err := sendRequest(ctx, connection, encoded.Bytes())
			// A lost response does not prove that the event was left unprocessed.
			if err != nil {
				return 0, err
			}
			if !response.RetryRegistration {
				if _, err := io.WriteString(os.Stdout, *response.Stdout); err != nil {
					return 0, err
				}
				if _, err := io.WriteString(os.Stderr, *response.Stderr); err != nil {
					return 0, err
				}
				return *response.ExitCode, nil
			}
			if event == "SessionEnd" {
				return 0, nil
			}
		}
		select {
		case <-registrationContext.Done():
			return 0, registrationContext.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

type serverResponse struct {
	Stdout            *string `json:"stdout"`
	Stderr            *string `json:"stderr"`
	ExitCode          *int    `json:"exit_code"`
	Registered        bool    `json:"registered"`
	RetryRegistration bool    `json:"retry_registration"`
}

func sendRequest(ctx context.Context, connection net.Conn, request []byte) (serverResponse, error) {
	defer connection.Close()
	var response serverResponse
	deadline, _ := ctx.Deadline()
	if err := connection.SetDeadline(deadline); err != nil {
		return response, err
	}
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		select {
		case <-ctx.Done():
			_ = connection.Close()
		case <-finished:
		}
	}()
	if _, err := io.Copy(connection, bytes.NewReader(request)); err != nil {
		return response, err
	}
	data, err := io.ReadAll(io.LimitReader(connection, 1024*1024+1))
	if err != nil {
		return response, err
	}
	if len(data) == 0 {
		return response, io.EOF
	}
	if len(data) > 1024*1024 || json.Unmarshal(data, &response) != nil || response.Stdout == nil || response.Stderr == nil || response.ExitCode == nil || *response.ExitCode < 0 || *response.ExitCode > 255 {
		return response, errors.New("invalid server response")
	}
	return response, nil
}

var errStartupRace = errors.New("another rules server holds the startup ownership")

func lockExclusive(ctx context.Context, file *os.File) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return nil
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EAGAIN {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

func startServer(ctx context.Context, directory, server string, arguments []string, configuration string) (net.Conn, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(directory, 0700); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(directory, "startup.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if err := lockExclusive(ctx, lock); err != nil {
		return nil, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	address := filepath.Join(directory, "server.sock")
	if connection, err := (&net.Dialer{}).DialContext(ctx, "unix", address); err == nil {
		return connection, nil
	} else if !errors.Is(err, syscall.ENOENT) && !errors.Is(err, syscall.ECONNREFUSED) {
		return nil, err
	}
	lease, err := os.OpenFile(filepath.Join(directory, "server.lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	defer lease.Close()
	if err := lockExclusive(ctx, lease); err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lease.Fd()), syscall.LOCK_UN); err != nil {
		return nil, err
	}
	deadline, _ := ctx.Deadline()
	args := append(append([]string{}, arguments...), "--directory", directory, "--configuration", configuration, "--startup-deadline", strconv.FormatFloat(float64(deadline.UnixNano())/1e9, 'f', 9, 64))
	command := exec.Command(server, args...)
	command.Stderr = os.Stderr
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		return nil, err
	}
	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()
	for {
		if connection, err := (&net.Dialer{}).DialContext(ctx, "unix", address); err == nil {
			return connection, nil
		} else if !errors.Is(err, syscall.ENOENT) && !errors.Is(err, syscall.ECONNREFUSED) {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case err := <-exited:
			if err != nil {
				return nil, fmt.Errorf("rules server exited before readiness: %w", err)
			}
			return nil, errStartupRace
		case <-time.After(20 * time.Millisecond):
		}
	}
}

func textField(input map[string]json.RawMessage, name string) string {
	var value string
	_ = json.Unmarshal(input[name], &value)
	return value
}
