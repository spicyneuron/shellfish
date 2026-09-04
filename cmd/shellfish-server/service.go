package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const maxActionBytes = 1 << 20
const maxEventBytes = 1 << 20

// The client's frame queue. A client that cannot keep up is dropped and recovers
// by reopening the stream.
const clientQueue = 256

// Mirrors the format version lib/session/main.zsh writes into a session header.
const sessionFormatVersion = 1

// Proxies in front of the service cut idle connections, and a silent turn can
// outlast their timeouts.
var keepaliveInterval = 20 * time.Second

var keepaliveFrame = []byte(": keepalive\n\n")

var errClientAttached = errors.New("session already has a client")
var errStreamSettling = errors.New("session file is ahead of the stream")

// Service proxies one authenticated browser onto one Shellfish session: it
// replays the durable transcript, relays one exec child's JSONL, and hands turn,
// cancellation, and permission actions back to that child. The meaning of a
// transcript belongs to exec and its presentation to the browser, so neither is
// interpreted here.
type Service struct {
	sessionPath string
	accessCode  string
	header      sessionHeader
	exec        *Exec

	mu     sync.Mutex
	client chan json.RawMessage
	// Durable records the session holds, counted at the last replay and advanced
	// by each record a child emits, so a handoff can tell that the file has run
	// ahead of the stream.
	recordCount int
	turn        *turn
	pending     json.RawMessage
	draining    bool
}

// turn is the one child that may run at a time.
type turn struct {
	cancel  context.CancelFunc
	done    chan struct{}
	replies chan json.RawMessage
	// Set by the child's own reader goroutine and read once Run has returned.
	failed bool
}

type sessionHeader struct {
	Type          string `json:"type"`
	FormatVersion int    `json:"format_version"`
	Cwd           string `json:"cwd"`
	Harness       struct {
		Sandbox bool `json:"sandbox"`
		Tools   []struct {
			Name string `json:"name"`
		} `json:"tools"`
	} `json:"harness"`
}

func New(sessionPath, accessCode string, exec *Exec) (*Service, error) {
	records, err := readTranscript(sessionPath)
	if err != nil {
		return nil, err
	}
	header, err := checkHeader(records[0])
	if err != nil {
		return nil, err
	}
	return &Service{sessionPath: sessionPath, accessCode: accessCode, header: header,
		exec: exec, recordCount: len(records)}, nil
}

// checkHeader refuses an unsupported session or one from another directory.
func checkHeader(record json.RawMessage) (sessionHeader, error) {
	var header sessionHeader
	if err := json.Unmarshal(record, &header); err != nil ||
		header.Type != "session" || header.FormatVersion != sessionFormatVersion {
		return sessionHeader{}, errors.New("unsupported session header")
	}
	cwd, err := os.Getwd()
	if err == nil {
		cwd, err = filepath.EvalSymlinks(cwd)
	}
	if err != nil {
		return sessionHeader{}, fmt.Errorf("resolve working directory: %w", err)
	}
	if header.Cwd != cwd {
		return sessionHeader{}, fmt.Errorf("session belongs to %q, not %q", header.Cwd, cwd)
	}
	return header, nil
}

func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	log.Printf("request method=%s path=%q remote=%q", r.Method, r.URL.Path, r.RemoteAddr)
	provided, bearer := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !bearer || len(provided) != len(s.accessCode) ||
		subtle.ConstantTimeCompare([]byte(provided), []byte(s.accessCode)) != 1 {
		w.Header().Set("WWW-Authenticate", "Bearer")
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	switch {
	case r.URL.Path == "/session" && r.Method == http.MethodGet:
		s.streamSession(w, r)
	case r.URL.Path == "/turn" && r.Method == http.MethodPost:
		s.postTurn(w, r)
	case r.URL.Path == "/cancel" && r.Method == http.MethodPost:
		s.postCancel(w)
	case r.URL.Path == "/permission" && r.Method == http.MethodPost:
		s.postPermission(w, r)
	default:
		writeError(w, http.StatusNotFound, "not found")
	}
}

// streamSession is the client's whole view of the session and its only recovery
// path. It replays the durable transcript, closes that replay with a state frame,
// then forwards what the child emits from there.
func (s *Service) streamSession(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unavailable")
		return
	}
	client, replay, err := s.attach()
	if err != nil {
		log.Printf("session stream refused: %v", err)
		switch {
		case errors.Is(err, errClientAttached):
			writeError(w, http.StatusConflict, "session already has a client")
		case errors.Is(err, errStreamSettling):
			writeError(w, http.StatusServiceUnavailable, "session is settling")
		default:
			writeError(w, http.StatusInternalServerError, "cannot read session")
		}
		return
	}
	defer s.detach(client)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	write := func(payload []byte) bool {
		if _, err := w.Write(payload); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}
	for _, frame := range replay {
		if !write(sseFrame(frame)) {
			return
		}
	}
	log.Printf("session stream opened frames=%d", len(replay))

	ticker := time.NewTicker(keepaliveInterval)
	defer ticker.Stop()
	for {
		select {
		case frame, open := <-client:
			// A closed queue is the service dropping this client, which it has
			// already reported; anything else here is an ordinary disconnection.
			if !open || !write(sseFrame(frame)) {
				return
			}
		case <-ticker.C:
			if !write(keepaliveFrame) {
				return
			}
		case <-r.Context().Done():
			return
		}
	}
}

// attach claims the single client slot and returns the frames it must render
// before anything the child emits from now on.
func (s *Service) attach() (chan json.RawMessage, []json.RawMessage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client != nil {
		return nil, nil, errClientAttached
	}
	records, err := readTranscript(s.sessionPath)
	if err != nil {
		return nil, nil, err
	}
	// A child appends a record before it emits one, so the file can be ahead of
	// the stream for an instant. Fail the handoff instead of reconciling it: the
	// client reopens and finds the two consistent.
	if s.turn != nil && len(records) != s.recordCount {
		return nil, nil, errStreamSettling
	}
	s.recordCount = len(records)
	// The state frame closes the replay: everything before it is durable history,
	// everything after it is happening now. A pending permission request follows,
	// so a client that reopened mid-turn can still answer it.
	replay := append(records, stateFrame(s.turn != nil, ""))
	if s.pending != nil {
		replay = append(replay, s.pending)
	}
	s.client = make(chan json.RawMessage, clientQueue)
	return s.client, replay, nil
}

func (s *Service) detach(client chan json.RawMessage) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client == client {
		s.client = nil
	}
}

// publishLocked hands one frame to the client, dropping a client that has fallen
// behind so it recovers on a fresh replay.
func (s *Service) publishLocked(frame json.RawMessage) {
	if s.client == nil {
		return
	}
	select {
	case s.client <- frame:
	default:
		log.Print("session client fell behind; dropping it")
		close(s.client)
		s.client = nil
	}
}

func (s *Service) postTurn(w http.ResponseWriter, r *http.Request) {
	input, ok := readAction(w, r)
	if !ok {
		return
	}
	s.mu.Lock()
	if s.draining {
		s.mu.Unlock()
		writeError(w, http.StatusServiceUnavailable, "service is shutting down")
		return
	}
	if s.turn != nil {
		s.mu.Unlock()
		writeError(w, http.StatusConflict, "turn already active")
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	active := &turn{cancel: cancel, done: make(chan struct{}),
		replies: make(chan json.RawMessage, 1)}
	s.turn = active
	s.publishLocked(stateFrame(true, ""))
	s.mu.Unlock()

	// The turn outlives the request that submitted it; everything it produces
	// reaches the client on the session stream.
	go s.runTurn(ctx, active, input)
	w.WriteHeader(http.StatusAccepted)
	log.Printf("turn accepted input_bytes=%d", len(input))
}

// runTurn drives one child to completion and releases the session.
func (s *Service) runTurn(ctx context.Context, active *turn, input json.RawMessage) {
	err := s.exec.Run(ctx, input, active.replies, func(event json.RawMessage) {
		s.forward(active, event)
	})
	if err != nil {
		log.Printf("turn process failed: %v", err)
	}
	failure := ""
	if err != nil || active.failed {
		failure = "turn process failed"
	}
	s.mu.Lock()
	s.turn = nil
	s.pending = nil
	s.publishLocked(stateFrame(false, failure))
	s.mu.Unlock()
	active.cancel()
	close(active.done)
	log.Printf("turn finished failure=%q", failure)
}

// forward relays one child event. Only its type matters here: a record advances
// the transcript a later replay must match, a permission request stays pending
// until it is answered, and the rest passes straight through.
func (s *Service) forward(active *turn, event json.RawMessage) {
	// Nothing more from a child already declared invalid reaches the client.
	if active.failed {
		return
	}
	frame, ok := compactObject(event, maxEventBytes)
	var envelope struct {
		Type string `json:"type"`
	}
	if !ok || json.Unmarshal(frame, &envelope) != nil || envelope.Type == "" {
		log.Print("turn emitted an invalid event; terminating it")
		active.failed = true
		active.cancel()
		return
	}
	kind := envelope.Type
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case kind == "_tool_permission_request":
		s.pending = frame
	case !strings.HasPrefix(kind, "_"):
		s.recordCount++
	}
	s.publishLocked(frame)
}

// postCancel stops the active turn. Shellfish exec commits the interrupted turn
// on its way out, so the reply waits for the child to settle.
func (s *Service) postCancel(w http.ResponseWriter) {
	s.mu.Lock()
	active := s.turn
	s.mu.Unlock()
	if active == nil {
		writeError(w, http.StatusConflict, "no active turn")
		return
	}
	log.Print("turn cancellation requested")
	active.cancel()
	<-active.done
	w.WriteHeader(http.StatusNoContent)
}

// postPermission answers the pending request. Which decision is canonical, and
// whether it names that request, is exec's to judge.
func (s *Service) postPermission(w http.ResponseWriter, r *http.Request) {
	decision, ok := readAction(w, r)
	if !ok {
		return
	}
	s.mu.Lock()
	active := s.turn
	if active == nil || s.pending == nil {
		s.mu.Unlock()
		writeError(w, http.StatusConflict, "no pending permission request")
		return
	}
	s.pending = nil
	s.mu.Unlock()
	select {
	case active.replies <- decision:
		w.WriteHeader(http.StatusNoContent)
	case <-active.done:
		writeError(w, http.StatusConflict, "no pending permission request")
	}
}

// beginDrain prevents new turns and reports when the active turn has settled. A
// pending permission cannot be answered after shutdown disconnects the client,
// so that turn starts its normal cancellation immediately.
func (s *Service) beginDrain() <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.draining = true
	if s.turn != nil {
		if s.pending != nil {
			log.Print("cancelling active turn waiting for permission")
			s.turn.cancel()
		}
		return s.turn.done
	}
	done := make(chan struct{})
	close(done)
	return done
}

// readAction reads a bounded JSON object for the child's stdin. Canonical shape
// is exec's to validate; the boundary here is size and framing.
func readAction(w http.ResponseWriter, r *http.Request) (json.RawMessage, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxActionBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var oversized *http.MaxBytesError
		if errors.As(err, &oversized) {
			writeError(w, http.StatusRequestEntityTooLarge, "request is too large")
		} else {
			writeError(w, http.StatusBadRequest, "cannot read request")
		}
		return nil, false
	}
	action, ok := compactObject(body, maxActionBytes)
	if !ok {
		writeError(w, http.StatusBadRequest, "request must be a JSON object")
		return nil, false
	}
	return action, true
}

// stateFrame closes a replay and reports whether a turn is running.
func stateFrame(working bool, failure string) json.RawMessage {
	frame, _ := json.Marshal(struct {
		Type    string `json:"type"`
		Working bool   `json:"working"`
		Error   string `json:"error,omitempty"`
	}{Type: "state", Working: working, Error: failure})
	return frame
}

func readTranscript(path string) ([]json.RawMessage, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("open session: %w", err)
	}
	// One record per line, so a trailing fragment is a record a killed writer never
	// finished. The service reads only and must not repair it; the records before it
	// are the session, and the next writer discards the rest.
	if end := bytes.LastIndexByte(body, '\n'); end < 0 {
		body = nil
	} else {
		body = body[:end]
	}
	if len(body) == 0 {
		return nil, errors.New("session transcript is empty")
	}
	lines := bytes.Split(body, []byte{'\n'})
	records := make([]json.RawMessage, 0, len(lines))
	for _, line := range lines {
		record := bytes.Trim(line, " \t\r")
		if len(record) <= 1 || record[0] != '{' || !json.Valid(record) {
			return nil, errors.New("invalid session transcript")
		}
		records = append(records, bytes.Clone(record))
	}
	return records, nil
}

// compactObject bounds one JSON object and reduces it to the single line an SSE
// frame or a child's stdin can carry.
func compactObject(data []byte, limit int) (json.RawMessage, bool) {
	if len(data) > limit {
		return nil, false
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, data); err != nil {
		return nil, false
	}
	value := compact.Bytes()
	if len(value) <= 1 || value[0] != '{' {
		return nil, false
	}
	return value, true
}

func sseFrame(frame json.RawMessage) []byte {
	return []byte("data: " + string(frame) + "\n\n")
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
