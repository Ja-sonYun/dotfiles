package logclient

import (
	"encoding/json"
	"os"
	"sync"
	"syscall"
	"time"
)

const MaxFrame = 32 * 1024

type Record struct {
	Time      string            `json:"time"`
	Component string            `json:"component"`
	Level     string            `json:"level"`
	Event     string            `json:"event"`
	PID       int               `json:"pid"`
	Fields    map[string]string `json:"fields,omitempty"`
}

// Client holds a reusable connection guarded by a try-lock.
type Client struct {
	mu   sync.Mutex
	fd   int
	open bool
	path string
}

// Send attempts one nonblocking write and closes the connection on a short write or error.
func (c *Client) Send(path string, entry Record) {
	if path == "" || len(path) > 103 || !c.mu.TryLock() {
		return
	}
	defer c.mu.Unlock()

	data, err := json.Marshal(entry)
	if err != nil || len(data)+1 > MaxFrame {
		return
	}
	data = append(data, '\n')

	if c.open && c.path != path {
		c.close()
	}
	if !c.open {
		fd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
		if err != nil {
			return
		}
		c.fd, c.open, c.path = fd, true, path
		syscall.CloseOnExec(fd)
		if syscall.SetNonblock(fd, true) != nil || syscall.Connect(fd, &syscall.SockaddrUnix{Name: path}) != nil {
			c.close()
			return
		}
	}
	if n, err := syscall.Write(c.fd, data); err != nil || n != len(data) {
		c.close()
	}
}

func (c *Client) Log(path, component, level, event string, fields map[string]string) {
	c.Send(path, Record{
		Time:      time.Now().UTC().Format(time.RFC3339Nano),
		Component: component,
		Level:     level,
		Event:     event,
		PID:       os.Getpid(),
		Fields:    fields,
	})
}

func (c *Client) close() {
	syscall.Close(c.fd)
	c.open = false
}
