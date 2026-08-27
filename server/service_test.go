package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testAccessCode = "123456"

const userRecord = `{"type":"message","role":"user","content":[{"type":"text","text":"go"}]}`
const assistantRecord = `{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"done"}]}`

func workDir(t *testing.T) string {
	t.Helper()
	cwd, err := os.Getwd()
	if err == nil {
		cwd, err = filepath.EvalSymlinks(cwd)
	}
	if err != nil {
		t.Fatal(err)
	}
	return cwd
}

// headerLine builds a session header the service will serve: current format and
// owned by the directory the test runs in.
func headerLine(t *testing.T) string {
	t.Helper()
	record, err := json.Marshal(map[string]any{
		"type": "session", "format_version": 1, "cwd": workDir(t),
		"harness": map[string]any{"sandbox": false},
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(record) + "\n"
}

func newSession(t *testing.T, records string) string {
	t.Helper()
	sessionPath := filepath.Join(t.TempDir(), "session.jsonl")
	if err := os.WriteFile(sessionPath, []byte(headerLine(t)+records), 0o600); err != nil {
		t.Fatal(err)
	}
	return sessionPath
}

// newTestServer serves a session whose turns run the given shell script in place
// of shellfish exec, so a script can append to the session file exactly as a
// turn would.
func newTestServer(t *testing.T, sessionPath, script string) string {
	t.Helper()
	binary := fakeShellfish(t, script)
	service, err := New(sessionPath, testAccessCode,
		NewExec(context.Background(), binary, sessionPath))
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(service)
	t.Cleanup(server.Close)
	return server.URL
}

func request(t *testing.T, method, url, body string) *http.Response {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	req, err := http.NewRequestWithContext(ctx, method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testAccessCode)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { response.Body.Close() })
	return response
}

func post(t *testing.T, url, body string, want int) {
	t.Helper()
	if response := request(t, http.MethodPost, url, body); response.StatusCode != want {
		t.Fatalf("POST %s status = %d, want %d", url, response.StatusCode, want)
	}
}

// stream reads one session connection's frames.
type stream struct {
	lines *bufio.Scanner
	body  io.Closer
}

// openStream connects and asserts the status. A reload races the previous
// connection's teardown, which a real client also retries through.
func openStream(t *testing.T, base string, want int) *stream {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		response := request(t, http.MethodGet, base+"/session", "")
		if response.StatusCode == want {
			if want != http.StatusOK {
				return nil
			}
			return &stream{lines: bufio.NewScanner(response.Body), body: response.Body}
		}
		if want != http.StatusOK || response.StatusCode != http.StatusConflict ||
			time.Now().After(deadline) {
			t.Fatalf("GET /session status = %d, want %d", response.StatusCode, want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// next returns the next frame, skipping keepalives and frame separators.
func (s *stream) next(t *testing.T) string {
	t.Helper()
	for s.lines.Scan() {
		if frame, ok := strings.CutPrefix(s.lines.Text(), "data: "); ok {
			return frame
		}
	}
	t.Fatal("session stream ended before the next frame")
	return ""
}

func (s *stream) expect(t *testing.T, want ...string) {
	t.Helper()
	for _, frame := range want {
		if got := s.next(t); got != frame {
			t.Fatalf("frame = %s, want %s", got, frame)
		}
	}
}

// waitFor blocks a script until the test creates the named file.
func waitFor(path string) string {
	return "while [ ! -f '" + path + "' ]; do sleep 0.02; done\n"
}

func TestUnauthorized(t *testing.T) {
	base := newTestServer(t, newSession(t, ""), "")
	for _, path := range []string{"/session", "/turn", "/cancel", "/permission"} {
		response, err := http.Get(base + path)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s without an access code = %d", path, response.StatusCode)
		}
	}
}

// A connection replays the durable session, closes it with a state frame, then
// forwards what the child emits. The client sees no other ordering.
func TestReplayThenStateThenLive(t *testing.T) {
	recorded := filepath.Join(t.TempDir(), "input")
	sessionPath := newSession(t, "")
	base := newTestServer(t, sessionPath, `
IFS= read -r input
printf '%s\n' "$input" >'`+recorded+`'
printf '%s\n' '{"type":"_assistant_delta","text":"do","seq":0}'
printf '%s\n' '`+userRecord+`' >>'`+sessionPath+`'
printf '%s\n' '`+userRecord+`'
printf '%s\n' '`+assistantRecord+`' >>'`+sessionPath+`'
printf '%s\n' '`+assistantRecord+`'
`)
	session := openStream(t, base, http.StatusOK)
	session.expect(t, strings.TrimSuffix(headerLine(t), "\n"), `{"type":"state","working":false}`)

	post(t, base+"/turn", userRecord, http.StatusAccepted)
	session.expect(t, `{"type":"state","working":true}`,
		`{"type":"_assistant_delta","text":"do","seq":0}`, userRecord, assistantRecord,
		`{"type":"state","working":false}`)

	if got, err := os.ReadFile(recorded); err != nil || string(got) != userRecord+"\n" {
		t.Fatalf("child input = %q (%v)", got, err)
	}
	if got, err := os.ReadFile(sessionPath); err != nil ||
		string(got) != headerLine(t)+userRecord+"\n"+assistantRecord+"\n" {
		t.Fatalf("session = %q (%v)", got, err)
	}
}

func TestOneClient(t *testing.T) {
	base := newTestServer(t, newSession(t, ""), "")
	openStream(t, base, http.StatusOK)
	openStream(t, base, http.StatusConflict)
}

func TestOneActiveTurn(t *testing.T) {
	release := filepath.Join(t.TempDir(), "release")
	base := newTestServer(t, newSession(t, ""), "IFS= read -r input\n"+waitFor(release))
	post(t, base+"/turn", userRecord, http.StatusAccepted)
	post(t, base+"/turn", userRecord, http.StatusConflict)
	if err := os.WriteFile(release, nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestTurnInputBounds(t *testing.T) {
	base := newTestServer(t, newSession(t, ""), "")
	post(t, base+"/turn", "not json", http.StatusBadRequest)
	post(t, base+"/turn", `[{"type":"message"}]`, http.StatusBadRequest)
	post(t, base+"/turn", `{"type":"message","text":"`+strings.Repeat("x", maxActionBytes)+`"}`,
		http.StatusRequestEntityTooLarge)
}

// Cancellation targets whatever turn is running, and waits for the child to
// commit its interrupted turn before answering.
func TestCancelCurrentTurn(t *testing.T) {
	base := newTestServer(t, newSession(t, ""), "IFS= read -r input\nwhile :; do sleep 0.05; done\n")
	post(t, base+"/cancel", "", http.StatusConflict)

	session := openStream(t, base, http.StatusOK)
	session.expect(t, strings.TrimSuffix(headerLine(t), "\n"), `{"type":"state","working":false}`)
	post(t, base+"/turn", userRecord, http.StatusAccepted)
	session.expect(t, `{"type":"state","working":true}`)
	post(t, base+"/cancel", "", http.StatusNoContent)
	session.expect(t, `{"type":"state","working":false,"error":"turn process failed"}`)
	post(t, base+"/cancel", "", http.StatusConflict)
}

// One pending request at a time, answered without naming it, and presented again
// after the client reloads the stream.
func TestPermissionSurvivesReload(t *testing.T) {
	const permissionRequest = `{"type":"_tool_permission_request","id":"permission_1","tool":{"name":"shell","input":{}}}`
	const decision = `{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}`
	recorded := filepath.Join(t.TempDir(), "decision")
	base := newTestServer(t, newSession(t, ""), `
IFS= read -r input
printf '%s\n' '`+permissionRequest+`'
IFS= read -r response
printf '%s\n' "$response" >'`+recorded+`'
`)
	post(t, base+"/permission", decision, http.StatusConflict)

	session := openStream(t, base, http.StatusOK)
	session.expect(t, strings.TrimSuffix(headerLine(t), "\n"), `{"type":"state","working":false}`)
	post(t, base+"/turn", userRecord, http.StatusAccepted)
	session.expect(t, `{"type":"state","working":true}`, permissionRequest)

	// A reload replays the session and presents the request again.
	session.body.Close()
	session = openStream(t, base, http.StatusOK)
	session.expect(t, strings.TrimSuffix(headerLine(t), "\n"),
		`{"type":"state","working":true}`, permissionRequest)

	post(t, base+"/permission", decision, http.StatusNoContent)
	post(t, base+"/permission", decision, http.StatusConflict)
	session.expect(t, `{"type":"state","working":false}`)
	if got, err := os.ReadFile(recorded); err != nil || string(got) != decision+"\n" {
		t.Fatalf("child decision = %q (%v)", got, err)
	}
}

// The child appends a record before it emits one, so a connection that finds the
// file ahead of the stream fails rather than reconciling the two.
func TestReloadFailsWhileSessionSettles(t *testing.T) {
	release := filepath.Join(t.TempDir(), "release")
	appended := filepath.Join(t.TempDir(), "appended")
	sessionPath := newSession(t, "")
	base := newTestServer(t, sessionPath, "IFS= read -r input\n"+
		`printf '%s\n' '`+userRecord+`' >>'`+sessionPath+`'`+"\n"+
		"printf done >'"+appended+"'\n"+waitFor(release))
	post(t, base+"/turn", userRecord, http.StatusAccepted)
	for deadline := time.Now().Add(5 * time.Second); ; {
		if _, err := os.Stat(appended); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the turn never appended its record")
		}
		time.Sleep(10 * time.Millisecond)
	}
	openStream(t, base, http.StatusServiceUnavailable)
	if err := os.WriteFile(release, nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

// An event the proxy cannot frame ends the turn instead of reaching the client.
func TestInvalidEventTerminatesTurn(t *testing.T) {
	base := newTestServer(t, newSession(t, ""), "IFS= read -r input\nprintf '%s\\n' 'not json'\n"+
		"while :; do sleep 0.05; done\n")
	session := openStream(t, base, http.StatusOK)
	session.expect(t, strings.TrimSuffix(headerLine(t), "\n"), `{"type":"state","working":false}`)
	post(t, base+"/turn", userRecord, http.StatusAccepted)
	session.expect(t, `{"type":"state","working":true}`,
		`{"type":"state","working":false,"error":"turn process failed"}`)
}

func TestUnknownPath(t *testing.T) {
	base := newTestServer(t, newSession(t, ""), "")
	if response := request(t, http.MethodGet, base+"/turn", ""); response.StatusCode != http.StatusNotFound {
		t.Fatalf("GET /turn status = %d, want %d", response.StatusCode, http.StatusNotFound)
	}
	if response := request(t, http.MethodPost, base+"/nowhere", "{}"); response.StatusCode != http.StatusNotFound {
		t.Fatalf("POST /nowhere status = %d, want %d", response.StatusCode, http.StatusNotFound)
	}
}
