package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

func socketLock(path string) (*os.File, error) {
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, err
	}
	return lock, nil
}

func removeSocket(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return errors.New("logger socket path is occupied by a non-socket file")
	}
	return os.Remove(path)
}

func cleanup(path string) error {
	lock, err := socketLock(path)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.EWOULDBLOCK) {
		return nil
	}
	if err != nil {
		return err
	}
	defer lock.Close()
	return removeSocket(path)
}

func serve(cfg settings) error {
	if err := os.MkdirAll(filepath.Dir(cfg.SocketPath), 0700); err != nil {
		return err
	}
	lock, err := socketLock(cfg.SocketPath)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = removeSocket(cfg.SocketPath); err != nil {
		return err
	}
	output, err := openWriter(cfg)
	if err != nil {
		return err
	}
	defer func() { output.file.Close() }()
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: cfg.SocketPath, Net: "unix"})
	if err != nil {
		return err
	}
	defer listener.Close()
	if err = os.Chmod(cfg.SocketPath, 0600); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	queue := make(chan record, 64)
	var dropped atomic.Uint64
	var connections sync.Map
	go func() {
		<-ctx.Done()
		listener.Close()
		connections.Range(func(key, _ any) bool {
			key.(*net.UnixConn).Close()
			return true
		})
	}()
	acceptError := make(chan error, 1)
	go func() {
		for {
			connection, err := listener.AcceptUnix()
			if err != nil {
				acceptError <- err
				return
			}
			connections.Store(connection, struct{}{})
			if ctx.Err() != nil {
				connection.Close()
				connections.Delete(connection)
				return
			}
			go func() {
				defer connection.Close()
				defer connections.Delete(connection)
				reader := bufio.NewReaderSize(connection, maxFrame)
				for {
					line, err := reader.ReadSlice('\n')
					if err != nil {
						if len(line) != 0 {
							dropped.Add(1)
						}
						return
					}
					var entry record
					if json.Unmarshal(line, &entry) != nil || levels[entry.Level] == 0 {
						dropped.Add(1)
						continue
					}
					if levels[entry.Level] < levels[cfg.Level] {
						continue
					}
					stamp, err := time.Parse(time.RFC3339Nano, entry.Time)
					if err != nil {
						dropped.Add(1)
						continue
					}
					entry.Time = stamp.UTC().Format(time.RFC3339Nano)
					select {
					case queue <- entry:
					default:
						dropped.Add(1)
					}
				}
			}()
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-acceptError:
			if ctx.Err() != nil {
				return nil
			}
			return err
		case entry := <-queue:
			if count := dropped.Swap(0); count != 0 && levels["warning"] >= levels[cfg.Level] {
				summary := record{
					Time:      time.Now().UTC().Format(time.RFC3339Nano),
					Component: "logger",
					Level:     "warning",
					Event:     "dropped",
					PID:       os.Getpid(),
					Fields:    map[string]string{"count": strconv.FormatUint(count, 10)},
				}
				if err := output.append(bounded(summary, cfg.MaxBytes)); err != nil {
					return err
				}
			}
			if err := output.append(bounded(entry, cfg.MaxBytes)); err != nil {
				return err
			}
		}
	}
}
