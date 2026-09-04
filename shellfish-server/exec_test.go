package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// fakeShellfish installs a stand-in for the shellfish executable.
func fakeShellfish(t *testing.T, script string) string {
	t.Helper()
	binary := filepath.Join(t.TempDir(), "shellfish")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\n"+script), 0o700); err != nil {
		t.Fatal(err)
	}
	return binary
}

func TestExecInvokesShellfish(t *testing.T) {
	recorded := filepath.Join(t.TempDir(), "invocation")
	binary := fakeShellfish(t, `printf '%s\n' "$*" >'`+recorded+`'
IFS= read -r input
printf '%s' "$input" >>'`+recorded+`'
printf '%s\n' '{"type":"_assistant_delta","text":"working"}' ''
`)
	session := "/sessions/served.jsonl"
	input := json.RawMessage(`{"type":"message","role":"user","content":[{"type":"text","text":"go"}]}`)
	var events []string
	err := NewExec(context.Background(), binary, session).Run(context.Background(), input, nil,
		func(event json.RawMessage) { events = append(events, string(event)) })
	if err != nil {
		t.Fatal(err)
	}
	want := "exec --jsonl --session " + session + "\n" + string(input)
	if invocation, err := os.ReadFile(recorded); err != nil || string(invocation) != want {
		t.Fatalf("invocation = %q, want %q (%v)", invocation, want, err)
	}
	// Blank lines are skipped and surrounding whitespace never reaches a client.
	if len(events) != 1 || events[0] != `{"type":"_assistant_delta","text":"working"}` {
		t.Fatalf("events = %q", events)
	}
}

func TestCreateSessionForwardsShellfishOptions(t *testing.T) {
	recorded := filepath.Join(t.TempDir(), "invocation")
	binary := fakeShellfish(t, `printf '%s\n' "$*" >'`+recorded+`'
printf '%s\n' /sessions/new.jsonl
`)
	session, err := createSession(binary, []string{"--profile", "work", "--model", "test"})
	if err != nil {
		t.Fatal(err)
	}
	if session != "/sessions/new.jsonl" {
		t.Fatalf("session = %q", session)
	}
	if got, err := os.ReadFile(recorded); err != nil ||
		string(got) != "exec --new --profile work --model test\n" {
		t.Fatalf("invocation = %q (%v)", got, err)
	}
}

func TestParseServerArgsStripsServerOptions(t *testing.T) {
	options, err := parseServerArgs([]string{
		"--bind", "127.0.0.1:0", "--shellfish", "/bin/shellfish",
		"--profile", "work", "--config", "shellfish.jsonc",
	})
	if err != nil {
		t.Fatal(err)
	}
	if options.bind != "127.0.0.1:0" || options.binary != "/bin/shellfish" {
		t.Fatalf("options = %#v", options)
	}
	if got, want := strings.Join(options.shellfishArgs, " "), "--profile work --config shellfish.jsonc"; got != want {
		t.Fatalf("Shellfish options = %q, want %q", got, want)
	}

}

func TestParseServerArgsRejectsExistingSessionOptions(t *testing.T) {
	_, err := parseServerArgs([]string{"--session", "session.jsonl", "--profile", "work"})
	if err == nil || err.Error() != "Shellfish options require creating a new session" {
		t.Fatalf("existing session options error = %v", err)
	}
}

func TestParseServerArgsHandlesHelp(t *testing.T) {
	for _, args := range [][]string{{"--help"}, {"-h"}} {
		options, err := parseServerArgs(args)
		if err != nil || !options.help {
			t.Errorf("parseServerArgs(%q) help = %v, error = %v", args, options.help, err)
		}
	}
	options, err := parseServerArgs([]string{"--", "--help"})
	if err != nil || options.help || strings.Join(options.shellfishArgs, " ") != "-- --help" {
		t.Errorf("forwarded help options = %#v, error = %v", options, err)
	}
}

func TestExecWritesPermissionResponse(t *testing.T) {
	recorded := filepath.Join(t.TempDir(), "input")
	binary := fakeShellfish(t, `
IFS= read -r input
printf '%s\n' "$input" >'`+recorded+`'
printf '%s\n' '{"type":"_tool_permission_request","id":"permission_1","tool":{"call_id":"call_1","name":"shell","input":{}}}'
IFS= read -r response
printf '%s\n' "$response" >>'`+recorded+`'
`)
	replies := make(chan json.RawMessage, 1)
	replies <- json.RawMessage(`{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}`)
	input := json.RawMessage(`{"type":"message","role":"user","content":[{"type":"text","text":"go"}]}`)
	if err := NewExec(context.Background(), binary, "/session").Run(
		context.Background(), input, replies, func(json.RawMessage) {}); err != nil {
		t.Fatal(err)
	}
	want := string(input) + "\n" + `{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}` + "\n"
	if got, err := os.ReadFile(recorded); err != nil || string(got) != want {
		t.Fatalf("input = %q, want %q (%v)", got, want, err)
	}
}

func TestExecRejectsOversizedOutput(t *testing.T) {
	// The trailing output has to exceed the pipe buffer, or the child would exit
	// on its own and never prove that its output is drained.
	oversized := `head -c ` + strconv.Itoa(maxEventBytes+1) + ` /dev/zero | tr '\0' x` + "\necho\n"
	binary := fakeShellfish(t, oversized+oversized)
	failed := make(chan error, 1)
	go func() {
		failed <- NewExec(context.Background(), binary, "/sessions/served.jsonl").Run(
			context.Background(), json.RawMessage(`{}`), nil,
			func(json.RawMessage) { t.Error("oversized event was emitted") })
	}()
	select {
	case err := <-failed:
		if err == nil || !strings.Contains(err.Error(), "read turn output") {
			t.Fatalf("error = %v, want a read failure", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("exec hung on an unread child")
	}
}

// Cancelling signals Shellfish exec itself, which lets it close the interrupted turn;
// its descendants are never signalled directly. Whatever outlives the grace
// period is killed with the process group.
func TestExecTerminatesThenKillsItsGroup(t *testing.T) {
	previous := cancelGracePeriod
	cancelGracePeriod = 100 * time.Millisecond
	t.Cleanup(func() { cancelGracePeriod = previous })

	dir := t.TempDir()
	ready := filepath.Join(dir, "ready")
	parentTerminated := filepath.Join(dir, "parent-terminated")
	childTerminated := filepath.Join(dir, "child-terminated")
	childPID := filepath.Join(dir, "child-pid")
	script := "trap 'printf terminated >\"" + parentTerminated + "\"; " +
		"printf \"%s\\n\" \"{\\\"type\\\":\\\"message\\\",\\\"role\\\":\\\"assistant\\\",\\\"stop\\\":\\\"end\\\",\\\"content\\\":[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"Turn interrupted.\\\"}]}\"; exit 143' TERM\n" +
		"(\n" +
		"  trap 'printf terminated >\"" + childTerminated + "\"; exit 143' TERM\n" +
		"  while :; do sleep 0.05; done\n" +
		") &\n" +
		"worker=$!\n" +
		"printf '%s' \"$worker\" >\"" + childPID + "\"\n" +
		"printf ready >\"" + ready + "\"\n" +
		"wait \"$worker\"\n"
	binary := fakeShellfish(t, script)
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan error, 1)
	var events []string
	go func() {
		finished <- NewExec(context.Background(), binary, "/session").Run(
			ctx, json.RawMessage(`{}`), nil, func(event json.RawMessage) {
				events = append(events, string(event))
			})
	}()
	for deadline := time.Now().Add(5 * time.Second); ; {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("turn process did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("interrupted turn reported completion")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("interrupted turn did not exit")
	}
	if _, err := os.Stat(parentTerminated); err != nil {
		t.Fatal("turn process did not receive SIGTERM")
	}
	if _, err := os.Stat(childTerminated); err == nil {
		t.Fatal("cancellation signalled a descendant instead of Shellfish exec alone")
	}
	if len(events) != 1 || events[0] != `{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"Turn interrupted."}]}` {
		t.Fatalf("cancellation events = %q", events)
	}
	pidText, err := os.ReadFile(childPID)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(string(pidText))
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(pid, 0); err == nil {
		t.Fatal("turn descendant survived cancellation")
	}
}
