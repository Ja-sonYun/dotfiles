package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/betterleaks/betterleaks/detect"
	"github.com/mattn/go-isatty"
	"github.com/rs/zerolog"
	"golang.org/x/sys/unix"
)

const commonRulesPath = "@COMMON_RULES_PATH@"

const usage = `Usage: redact [--rules PATH] [-- COMMAND ARG...]

Without COMMAND, redact stdin to stdout. With COMMAND, redact arguments as text
and piped/file stdin, then run COMMAND. Environment and terminal stdin pass through.
Output and exit status belong to COMMAND. Input is buffered until EOF.

Common rules load from the package's share/redact/common-rules.txt, one type:regex
per line. Types use lowercase letters, digits, and hyphens. Blank lines are ignored.
Missing or invalid common rules stop execution.

Personal rules default to ~/.config/redact/rules.txt, one value per line:
  $(MY_API_KEY)           Match the inherited environment variable's value
  my-private-password    Match literal text
  regex:company_[0-9]+    Match a Go regular expression
  regex:password=(\S+)    Redact only the first capture group
  text:$(LITERAL)         Match reserved syntax literally

Missing default rules, blank lines, and empty/unset environment references are
ignored. Other rules errors stop execution. Rules and input values are not logged.
Regex rules redact group 1 when present, otherwise the whole match. An unmatched
or empty group 1 is skipped. Argument boundaries survive redaction. JSON is not
parsed or re-encoded, so replacements can make JSON invalid.
`

func fail(message string) int {
	fmt.Fprintln(os.Stderr, "redact: "+message)
	return 1
}

func main() {
	os.Exit(run())
}

func run() int {
	var path string
	var command []string
	explicit := false
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--help" || args[i] == "-h":
			fmt.Print(usage)
			return 0
		case args[i] == "--":
			command = args[i+1:]
			if len(command) == 0 {
				return fail("expected a command after --")
			}
			i = len(args)
		case args[i] == "--rules":
			i++
			if i == len(args) || args[i] == "" {
				return fail("expected a rules path")
			}
			path, explicit = args[i], true
		case strings.HasPrefix(args[i], "--rules="):
			path, explicit = strings.TrimPrefix(args[i], "--rules="), true
			if path == "" {
				return fail("expected a rules path")
			}
		default:
			return fail("unknown option; use redact --help")
		}
	}

	if !explicit {
		home, err := os.UserHomeDir()
		if err != nil {
			return fail("cannot locate default rules directory")
		}
		path = filepath.Join(home, ".config", "redact", "rules.txt")
	}
	rules, err := loadRules(path, explicit)
	if err != nil {
		return fail(err.Error())
	}
	commonRules, err := loadCommonRules(commonRulesPath)
	if err != nil {
		return fail(err.Error())
	}
	zerolog.SetGlobalLevel(zerolog.Disabled)
	detector, err := detect.NewDetectorDefaultConfig()
	if err != nil {
		return fail("cannot initialize credential detector")
	}
	detector.IgnoreGitleaksAllow = true
	r := redactor{
		detector:    detector,
		rules:       rules,
		commonRules: commonRules,
	}

	if command != nil {
		return runCommand(command[0], r.arguments(command[1:]), &r)
	}
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		return fail("cannot read stdin")
	}
	if _, err := io.WriteString(os.Stdout, r.mask(string(input))); err != nil {
		return fail("cannot write stdout")
	}
	return 0
}

func moveTerminal(terminal *os.File, from, to int) error {
	if terminal == nil {
		return nil
	}
	foreground, err := unix.IoctlGetInt(int(terminal.Fd()), unix.TIOCGPGRP)
	if err != nil || foreground != from {
		return err
	}
	ignored := signal.Ignored(syscall.SIGTTOU)
	signal.Ignore(syscall.SIGTTOU)
	defer func() {
		if !ignored {
			signal.Reset(syscall.SIGTTOU)
		}
	}()
	return unix.IoctlSetPointerInt(int(terminal.Fd()), unix.TIOCSPGRP, to)
}

type commandEvent struct {
	status syscall.WaitStatus
	err    error
}

func runCommand(name string, args []string, r *redactor) int {
	path, err := exec.LookPath(name)
	if err != nil {
		fmt.Fprintln(os.Stderr, "redact: cannot find command")
		if errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
			return 127
		}
		return 126
	}
	stdin := os.Stdin
	stdinIsTerminal := isatty.IsTerminal(os.Stdin.Fd())
	var maskedInput string
	var reader, writer *os.File
	if !stdinIsTerminal {
		input, err := io.ReadAll(os.Stdin)
		if err != nil {
			return fail("cannot process stdin")
		}
		maskedInput = r.mask(string(input))

		reader, writer, err = os.Pipe()
		if err != nil {
			return fail("cannot create stdin pipe")
		}
		defer reader.Close()
		defer writer.Close()
		stdin = reader
	}

	parentGroup := syscall.Getpgrp()
	attributes := &syscall.SysProcAttr{Setpgid: true}
	terminal, terminalError := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if terminalError == nil {
		defer terminal.Close()
		foreground, err := unix.IoctlGetInt(int(terminal.Fd()), unix.TIOCGPGRP)
		if err != nil {
			return fail("cannot read terminal foreground group")
		}
		if foreground == parentGroup {
			attributes.Foreground = true
			attributes.Ctty = int(terminal.Fd())
		}
	} else if stdinIsTerminal {
		return fail("cannot open controlling terminal")
	}

	signals := make(chan os.Signal, 16)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT, syscall.SIGTSTP, syscall.SIGCONT)
	defer signal.Stop(signals)
	process, err := os.StartProcess(path, append([]string{name}, args...), &os.ProcAttr{
		Env:   os.Environ(),
		Files: []*os.File{stdin, os.Stdout, os.Stderr},
		Sys:   attributes,
	})
	if err != nil {
		if attributes.Foreground {
			if foreground, terminalErr := unix.IoctlGetInt(int(terminal.Fd()), unix.TIOCGPGRP); terminalErr == nil {
				if restoreErr := moveTerminal(terminal, foreground, parentGroup); restoreErr != nil {
					fmt.Fprintln(os.Stderr, "redact: cannot restore terminal foreground group")
				}
			}
		}
		fmt.Fprintln(os.Stderr, "redact: cannot start command")
		if errors.Is(err, os.ErrNotExist) {
			return 127
		}
		return 126
	}
	groupID := process.Pid
	defer process.Release()
	defer func() {
		if err := moveTerminal(terminal, groupID, parentGroup); err != nil {
			fmt.Fprintln(os.Stderr, "redact: cannot restore terminal foreground group")
		}
	}()

	inputError := make(chan struct{}, 1)
	if reader != nil {
		reader.Close()
		go func() {
			defer writer.Close()
			_, err := io.WriteString(writer, maskedInput)
			if err != nil && !errors.Is(err, syscall.EPIPE) && !errors.Is(err, os.ErrClosed) {
				inputError <- struct{}{}
			}
		}()
	}
	events := make(chan commandEvent, 4)
	// Observe job-control events with a single child reaper.
	go func() {
		for {
			var status syscall.WaitStatus
			_, err := syscall.Wait4(groupID, &status, syscall.WUNTRACED|syscall.WCONTINUED, nil)
			if errors.Is(err, syscall.EINTR) {
				continue
			}
			events <- commandEvent{status: status, err: err}
			if err != nil || status.Exited() || status.Signaled() {
				return
			}
		}
	}()

	groupAlive := true
	signalGroup := func(sig syscall.Signal) error {
		if !groupAlive {
			return nil
		}
		err := syscall.Kill(-groupID, sig)
		if errors.Is(err, syscall.ESRCH) {
			groupAlive = false
			return nil
		}
		return err
	}
	var timer *time.Timer
	var deadline <-chan time.Time
	cleaning := false
	beginCleanup := func() error {
		if cleaning {
			return nil
		}
		cleaning = true
		timer = time.NewTimer(3 * time.Second)
		deadline = timer.C
		if writer != nil {
			writer.Close()
		}
		if err := signalGroup(syscall.SIGTERM); err != nil {
			return err
		}
		if err := signalGroup(syscall.SIGCONT); err != nil {
			return err
		}
		return nil
	}
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	poll := time.NewTicker(50 * time.Millisecond)
	defer poll.Stop()
	var status syscall.WaitStatus
	leaderDone := false
	inputFailed := false
	waitFailed := false
	controlFailure := ""

	for {
		problem := ""
		select {
		case sig := <-signals:
			switch sig {
			case syscall.SIGCONT:
				if !cleaning && groupAlive {
					if err := moveTerminal(terminal, parentGroup, groupID); err != nil {
						problem = "cannot transfer terminal foreground group"
					}
				}
				if err := signalGroup(syscall.SIGCONT); err != nil {
					problem = "cannot resume command group"
				}
			case syscall.SIGTSTP:
				if !cleaning {
					if err := signalGroup(syscall.SIGTSTP); err != nil {
						problem = "cannot suspend command group"
					}
				}
			default:
				if err := beginCleanup(); err != nil {
					problem = "cannot terminate command group"
				}
			}
		case <-inputError:
			inputFailed = true
			if err := beginCleanup(); err != nil {
				problem = "cannot terminate command group"
			}
		case event := <-events:
			if event.err != nil {
				leaderDone, waitFailed = true, true
				if err := beginCleanup(); err != nil {
					problem = "cannot terminate command group"
				}
			} else if event.status.Stopped() {
				if cleaning {
					if err := signalGroup(syscall.SIGCONT); err != nil {
						problem = "cannot resume terminating command group"
					}
				} else {
					if err := moveTerminal(terminal, groupID, parentGroup); err != nil {
						problem = "cannot restore terminal foreground group"
					} else if err := syscall.Kill(os.Getpid(), syscall.SIGSTOP); err != nil {
						problem = "cannot suspend command wrapper"
					}
				}
			} else if event.status.Exited() || event.status.Signaled() {
				status, leaderDone = event.status, true
				if status.Signaled() {
					if err := beginCleanup(); err != nil {
						problem = "cannot terminate command group"
					}
				}
			}
		case <-deadline:
			deadline = nil
			if err := signalGroup(syscall.SIGKILL); err != nil {
				return fail("cannot kill command group")
			}
		case <-poll.C:
		}

		if err := signalGroup(0); err != nil && !errors.Is(err, syscall.EPERM) {
			problem = "cannot inspect command group"
		}
		if problem != "" {
			controlFailure = problem
			if err := beginCleanup(); err != nil {
				controlFailure = "cannot terminate command group"
			}
		}
		if leaderDone && !groupAlive {
			select {
			case <-inputError:
				inputFailed = true
			default:
			}
			if inputFailed {
				return fail("cannot process stdin")
			}
			if waitFailed {
				return fail("cannot wait for command")
			}
			if controlFailure != "" {
				return fail(controlFailure)
			}
			if status.Signaled() {
				return 128 + int(status.Signal())
			}
			return status.ExitStatus()
		}
	}
}
