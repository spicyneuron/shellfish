package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
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
// of shellfish run, so a script can append to the session file exactly as a
// turn would.
func newTestServer(t *testing.T, sessionPath, script string) string {
	t.Helper()
	binary := fakeShellfish(t, script)
	turns, cancelTurns := context.WithCancel(context.Background())
	service, err := New(sessionPath, testAccessCode,
		NewExec(turns, binary, sessionPath))
	if err != nil {
		cancelTurns()
		t.Fatal(err)
	}
	server := httptest.NewServer(service)
	t.Cleanup(func() {
		turnDone := service.beginDrain()
		cancelTurns()
		<-turnDone
		server.Close()
	})
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

func (s *stream) expectRaw(t *testing.T, want ...string) {
	t.Helper()
	for _, frame := range want {
		if got := s.next(t); got != frame {
			t.Fatalf("frame = %s, want %s", got, frame)
		}
	}
}

func (s *stream) expectJSON(t *testing.T, want ...string) {
	t.Helper()
	for _, frame := range want {
		var gotValue, wantValue any
		got := s.next(t)
		if err := json.Unmarshal([]byte(got), &gotValue); err != nil {
			t.Fatalf("frame is not JSON: %s", got)
		}
		if err := json.Unmarshal([]byte(frame), &wantValue); err != nil {
			t.Fatalf("expected frame is not JSON: %s", frame)
		}
		if !reflect.DeepEqual(gotValue, wantValue) {
			t.Fatalf("frame = %s, want %s", got, frame)
		}
	}
}

// waitFor blocks a script until the test creates the named file.
func waitFor(path string) string {
	return "while [ ! -f '" + path + "' ]; do sleep 0.02; done\n"
}

func TestReadTranscriptRequiresJSONLines(t *testing.T) {
	header := strings.TrimSuffix(headerLine(t), "\n")
	path := filepath.Join(t.TempDir(), "session.jsonl")
	read := func(content string) ([]json.RawMessage, error) {
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		return readTranscript(path)
	}
	records, err := read(header + "\n" + userRecord + "\n" + `{"type":`)
	if err != nil || len(records) != 2 {
		t.Fatalf("complete records = %d, error = %v", len(records), err)
	}
	invalid := []string{
		header + "\n \n" + userRecord + "\n",
		header + "\n{\n}\n",
		header + "\n[]\n",
		"\u00a0" + header + "\n",
	}
	for _, content := range invalid {
		if _, err := read(content); err == nil {
			t.Fatalf("readTranscript accepted %q", content)
		}
	}
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

func TestPublicAssets(t *testing.T) {
	handler := withUI(http.NotFoundHandler())
	assets := []struct {
		path        string
		contentType string
	}{
		{"/", "text/html; charset=utf-8"},
		{"/ui.css", "text/css; charset=utf-8"},
		{"/ui.js", "text/javascript; charset=utf-8"},
	}
	wantHeaders := map[string]string{
		"Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
		"X-Content-Type-Options":  "nosniff",
		"Referrer-Policy":         "no-referrer",
		"Cache-Control":           "no-store",
	}
	for _, asset := range assets {
		t.Run(asset.path, func(t *testing.T) {
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, asset.path, nil))
			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
			}
			if got := response.Header().Get("Content-Type"); got != asset.contentType {
				t.Errorf("Content-Type = %q, want %q", got, asset.contentType)
			}
			for name, want := range wantHeaders {
				if got := response.Header().Get(name); got != want {
					t.Errorf("%s = %q, want %q", name, got, want)
				}
			}
			if response.Body.Len() == 0 {
				t.Error("body is empty")
			}
		})
	}
}

func TestNewRejectsInvalidSessionHeader(t *testing.T) {
	cwd := workDir(t)
	tests := []struct {
		name      string
		header    map[string]any
		wantError string
	}{
		{"record type", map[string]any{"type": "message", "format_version": 1, "cwd": cwd}, "unsupported session header"},
		{"format version", map[string]any{"type": "session", "format_version": 2, "cwd": cwd}, "unsupported session header"},
		{"working directory", map[string]any{"type": "session", "format_version": 1, "cwd": t.TempDir()}, "session belongs to"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			record, err := json.Marshal(test.header)
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(t.TempDir(), "session.jsonl")
			if err := os.WriteFile(path, append(record, '\n'), 0o600); err != nil {
				t.Fatal(err)
			}
			_, err = New(path, testAccessCode, nil)
			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("error = %v, want containing %q", err, test.wantError)
			}
		})
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
	session.expectRaw(t, strings.TrimSuffix(headerLine(t), "\n"))
	session.expectJSON(t, `{"type":"state","working":false}`)

	post(t, base+"/turn", userRecord, http.StatusAccepted)
	session.expectJSON(t, `{"type":"state","working":true}`,
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
	session.expectRaw(t, strings.TrimSuffix(headerLine(t), "\n"))
	session.expectJSON(t, `{"type":"state","working":false}`)
	post(t, base+"/turn", userRecord, http.StatusAccepted)
	session.expectJSON(t, `{"type":"state","working":true}`)
	post(t, base+"/cancel", "", http.StatusNoContent)
	session.expectJSON(t, `{"type":"state","working":false,"error":"turn process failed"}`)
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
	session.expectRaw(t, strings.TrimSuffix(headerLine(t), "\n"))
	session.expectJSON(t, `{"type":"state","working":false}`)
	post(t, base+"/turn", userRecord, http.StatusAccepted)
	session.expectJSON(t, `{"type":"state","working":true}`, permissionRequest)

	// A reload replays the session and presents the request again.
	session.body.Close()
	session = openStream(t, base, http.StatusOK)
	session.expectRaw(t, strings.TrimSuffix(headerLine(t), "\n"))
	session.expectJSON(t, `{"type":"state","working":true}`, permissionRequest)

	post(t, base+"/permission", decision, http.StatusNoContent)
	post(t, base+"/permission", decision, http.StatusConflict)
	session.expectJSON(t, `{"type":"state","working":false}`)
	if got, err := os.ReadFile(recorded); err != nil || string(got) != decision+"\n" {
		t.Fatalf("child decision = %q (%v)", got, err)
	}
}

func TestDrainCancelsPendingPermission(t *testing.T) {
	const permissionRequest = `{"type":"_tool_permission_request","id":"permission_1","tool":{"name":"shell","input":{}}}`
	turns, cancelTurns := context.WithCancel(context.Background())
	defer cancelTurns()
	sessionPath := newSession(t, "")
	service, err := New(sessionPath, testAccessCode, NewExec(turns,
		fakeShellfish(t, "IFS= read -r input\nprintf '%s\\n' '"+permissionRequest+"'\nIFS= read -r response\n"),
		sessionPath))
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(service)
	defer server.Close()
	session := openStream(t, server.URL, http.StatusOK)
	defer session.body.Close()
	session.expectRaw(t, strings.TrimSuffix(headerLine(t), "\n"))
	session.expectJSON(t, `{"type":"state","working":false}`)
	post(t, server.URL+"/turn", userRecord, http.StatusAccepted)
	session.expectJSON(t, `{"type":"state","working":true}`, permissionRequest)

	select {
	case <-service.beginDrain():
	case <-time.After(2 * time.Second):
		t.Fatal("drain did not cancel the pending permission")
	}
}

func TestFirstSignalBoundsShutdownDrain(t *testing.T) {
	previous := shutdownDrainPeriod
	shutdownDrainPeriod = 50 * time.Millisecond
	defer func() { shutdownDrainPeriod = previous }()

	ready := filepath.Join(t.TempDir(), "ready")
	turns, killTurn := context.WithCancel(context.Background())
	defer killTurn()
	sessionPath := newSession(t, "")
	service, err := New(sessionPath, testAccessCode, NewExec(turns,
		fakeShellfish(t, "trap 'exit 143' TERM\nIFS= read -r input\nprintf ready >'"+ready+"'\nwhile :; do sleep 0.05; done\n"),
		sessionPath))
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	signals := make(chan os.Signal, 1)
	finished := make(chan error, 1)
	go func() { finished <- serveHTTP(listener, service, killTurn, signals) }()
	post(t, "http://"+listener.Addr().String()+"/turn", userRecord, http.StatusAccepted)
	for deadline := time.Now().Add(2 * time.Second); ; {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("turn did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}

	started := time.Now()
	signals <- os.Interrupt
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
		if time.Since(started) < shutdownDrainPeriod {
			t.Fatal("shutdown skipped the drain period")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("first signal did not bound shutdown")
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
	session.expectRaw(t, strings.TrimSuffix(headerLine(t), "\n"))
	session.expectJSON(t, `{"type":"state","working":false}`)
	post(t, base+"/turn", userRecord, http.StatusAccepted)
	session.expectJSON(t, `{"type":"state","working":true}`,
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
