package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

const maxDiagnosticBytes = 8 << 10

// A cancelled turn is given time to unwind: USR1 targets the Shellfish turn alone so
// it can finish cleanup before exiting. Killing the process group is the backstop for
// a child that cannot manage that.
var cancelGracePeriod = 5 * time.Second

// Exec runs Shellfish children against one stored session.
type Exec struct {
	ctx     context.Context
	binary  string
	session string
}

// NewExec binds every child to the service lifetime. Cancelling ctx is the
// forced-shutdown path; individual turns receive their own context in Run.
func NewExec(ctx context.Context, binary, session string) *Exec {
	return &Exec{ctx: ctx, binary: binary, session: session}
}

// Load returns the durable records of the session. Validation, an interrupted
// append's trailing fragment, and canonical meaning all belong to shellfish
// load. The transient path event it opens with is dropped here.
func (e *Exec) Load() ([]json.RawMessage, error) {
	child := exec.CommandContext(e.ctx, e.binary, "load", "--session", e.session)
	diagnostics := &tailBuffer{limit: maxDiagnosticBytes}
	child.Stderr = diagnostics
	output, err := child.Output()
	if err != nil {
		return nil, fmt.Errorf("load session: %w%s", err, diagnostics.suffix())
	}
	lines := bytes.Split(bytes.TrimSuffix(output, []byte{'\n'}), []byte{'\n'})
	var opening struct {
		Type string `json:"type"`
	}
	// The path event and the header are the shortest stream load can produce.
	if len(lines) < 2 || json.Unmarshal(lines[0], &opening) != nil ||
		opening.Type != "_session_load" {
		return nil, errors.New("load did not open with a session path")
	}
	records := make([]json.RawMessage, 0, len(lines)-1)
	for _, line := range lines[1:] {
		records = append(records, line)
	}
	return records, nil
}

func (e *Exec) Run(ctx context.Context, input json.RawMessage, replies <-chan json.RawMessage, emit func(json.RawMessage)) error {
	ctx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(e.ctx, cancel)
	defer func() {
		stop()
		cancel()
	}()
	args := []string{"run", "--jsonl", "--session", e.session}
	child := exec.CommandContext(ctx, e.binary, args...)
	// Detach from terminal job control while retaining a group for forced cleanup.
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	grace := cancelGracePeriod
	var processMu sync.Mutex
	processExited := false
	child.Cancel = func() error {
		err := child.Process.Signal(syscall.SIGUSR1)
		if errors.Is(err, os.ErrProcessDone) || errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		if err == nil {
			go func() {
				time.Sleep(grace)
				processMu.Lock()
				if !processExited {
					_ = syscall.Kill(-child.Process.Pid, syscall.SIGKILL)
				}
				processMu.Unlock()
			}()
		}
		return err
	}
	diagnostics := &tailBuffer{limit: maxDiagnosticBytes}
	child.Stderr = diagnostics
	stdin, err := child.StdinPipe()
	if err != nil {
		return fmt.Errorf("open turn input: %w", err)
	}
	stdout, err := child.StdoutPipe()
	if err != nil {
		return fmt.Errorf("open turn output: %w", err)
	}
	if err := child.Start(); err != nil {
		return fmt.Errorf("start turn process: %w", err)
	}
	if _, err := stdin.Write(append(input, '\n')); err != nil {
		_ = stdin.Close()
		_ = child.Wait()
		return fmt.Errorf("write turn input: %w%s", err, diagnostics.suffix())
	}
	inputDone := make(chan struct{})
	go func() {
		defer stdin.Close()
		for {
			select {
			case reply := <-replies:
				if _, err := stdin.Write(append(reply, '\n')); err != nil {
					return
				}
			case <-inputDone:
				return
			case <-ctx.Done():
				return
			}
		}
	}()
	lines := bufio.NewScanner(stdout)
	lines.Buffer(nil, maxEventBytes)
	for lines.Scan() {
		event := bytes.TrimSpace(lines.Bytes())
		if len(event) > 0 {
			emit(event)
		}
	}
	scanErr := lines.Err()
	if scanErr != nil {
		// Reading stopped early, and a child left writing into a full pipe would
		// never exit for Wait to reap.
		_, _ = io.Copy(io.Discard, stdout)
	}
	// Wait closes the pipe, so it has to follow the last read.
	waitErr := child.Wait()
	close(inputDone)
	processMu.Lock()
	processExited = true
	processMu.Unlock()
	switch {
	case scanErr != nil:
		return fmt.Errorf("read turn output: %w%s", scanErr, diagnostics.suffix())
	case waitErr != nil:
		return fmt.Errorf("turn process failed: %w%s", waitErr, diagnostics.suffix())
	}
	return nil
}

// tailBuffer keeps the most recent diagnostics from a child's stderr, bounded
// because a child can write any amount of it before it fails.
type tailBuffer struct {
	limit     int
	data      []byte
	truncated bool
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.data = append(b.data, p...)
	if len(b.data) > b.limit {
		b.data = b.data[len(b.data)-b.limit:]
		b.truncated = true
	}
	return len(p), nil
}

// suffix renders the diagnostics for appending to an error message, or nothing
// when the child stayed quiet.
func (b *tailBuffer) suffix() string {
	text := strings.TrimSpace(string(b.data))
	if text == "" {
		return ""
	}
	if b.truncated {
		text = "..." + text
	}
	return ": " + text
}
