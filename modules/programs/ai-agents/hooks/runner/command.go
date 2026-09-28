package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

func runCommand(command string, input []byte, timeout int, failure bool) int {
	cmd := exec.Command("/bin/sh", "-c", command)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cannot open hook input:", err)
		return 1
	}
	defer stdin.Close()
	var output bytes.Buffer
	var readPipe, writePipe *os.File
	var copied chan error
	if failure {
		var err error
		readPipe, writePipe, err = os.Pipe()
		if err != nil {
			fmt.Fprintln(os.Stderr, "Cannot capture hook output:", err)
			return 1
		}
		defer readPipe.Close()
		defer writePipe.Close()
		cmd.Stdout = writePipe
	}
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "Cannot start hook command:", err)
		return 1
	}
	sent := make(chan struct{}, 1)
	go func(done chan<- struct{}) {
		_, _ = stdin.Write(input)
		_ = stdin.Close()
		done <- struct{}{}
	}(sent)
	if failure {
		_ = writePipe.Close()
		copied = make(chan error, 1)
		go func(done chan<- error) {
			_, err := io.Copy(&output, readPipe)
			done <- err
		}(copied)
	}
	exitWatch := make(chan error, 1)
	go func(done chan<- error) {
		done <- watchChild(cmd.Process.Pid)
	}(exitWatch)
	var timer *time.Timer
	var deadline <-chan time.Time
	if timeout > 0 {
		timer = time.NewTimer(time.Duration(timeout) * time.Second)
		deadline = timer.C
		defer timer.Stop()
	}
	forced := 0
	var forwarding syscall.Signal
	for (exitWatch != nil || copied != nil || sent != nil) && forced == 0 {
		select {
		case <-sent:
			sent = nil
		case err := <-exitWatch:
			exitWatch = nil
			if err != nil {
				fmt.Fprintln(os.Stderr, "Cannot watch hook command:", err)
				forced, forwarding = 1, syscall.SIGTERM
			}
		case err := <-copied:
			copied = nil
			if err != nil {
				forced, forwarding = 1, syscall.SIGTERM
			}
		case received := <-signals:
			forwarding = received.(syscall.Signal)
			forced = 128 + int(forwarding)
		case <-deadline:
			forced, forwarding = 124, syscall.SIGTERM
		}
	}
	if forced != 0 {
		_ = syscall.Kill(-cmd.Process.Pid, forwarding)
		// Keep the leader unreaped until group cleanup prevents PID reuse.
		grace := time.NewTimer(3 * time.Second)
		select {
		case <-grace.C:
		case <-signals:
			grace.Stop()
		}
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	err = cmd.Wait()
	if forced != 0 && readPipe != nil {
		_ = readPipe.Close()
	}
	if sent != nil {
		<-sent
	}
	if exitWatch != nil {
		<-exitWatch
	}
	if copied != nil {
		<-copied
	}
	if failure {
		_, _ = os.Stdout.Write(restoreFailure(output.Bytes()))
	}
	if forced != 0 {
		return forced
	}
	if err != nil && cmd.ProcessState != nil {
		if status, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return 128 + int(status.Signal())
		}
		if cmd.ProcessState.ExitCode() >= 0 {
			return cmd.ProcessState.ExitCode()
		}
		return 1
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cannot wait for hook command:", err)
		return 1
	}
	return 0
}
