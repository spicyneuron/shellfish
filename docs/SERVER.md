# shellfish-server

One Shellfish session, one browser, over HTTP. The server is a proxy and nothing more: `shellfish exec --jsonl` runs the turn and owns the session, and the page decides how any of it looks. Between them the server authenticates, starts one child at a time, and forwards bytes.

```text
browser
  GET  /session     <---- replayed session, state boundary, then live exec JSONL
  POST /turn        ----> authenticated server ----> shellfish exec --jsonl
  POST /cancel      ---->                      ----> signal the active child
  POST /permission  ---->                      ----> the child's standard input
```

Build and run it from the directory the session belongs to:

```sh
go build -o shellfish-server ./server
./shellfish-server
```

Pass Shellfish options to create a session with a particular runtime:

```sh
./shellfish-server --profile work --model MODEL
```

To serve an existing session instead:

```sh
./shellfish-server --session path/to/session.jsonl
```

Without `--session`, the server forwards its non-server options to `shellfish exec --new`, then serves the path Shellfish returns. `--bind` and `--shellfish` stay with the server. The server refuses a session whose recorded working directory is not the directory it was started in.

## Access

Every API request carries `Authorization: Bearer CODE`, where `CODE` is the six startup digits without the display hyphen (`123456`, not `123-456`). The page itself and its static assets are served without authentication. After entry, the page keeps the code only in `sessionStorage`, so reloads in that tab reconnect automatically and closing the tab clears it. `detach session` clears the stored code and reloads the page.

The page escapes transcript content and its content security policy restricts resources to the bundled same-origin assets. These are defense-in-depth controls, not a substitute for keeping the bearer code and transport private.

The bind address defaults to loopback. Anything else warns at startup and should sit behind TLS. A reverse proxy must preserve the `Authorization` header, disable buffering for `/session`, and allow long-lived SSE responses.

## The session stream

`GET /session` is the client's entire view of the session and its only recovery. A connection replays the durable JSONL as it stands, sends a `state` frame that closes the replay, and then forwards what the child emits. Reopening it is how a client recovers from a disconnect, an unexpected frame, missed work, or an uncertain ending; the server never reconciles anything on the client's behalf.

Only one client may be attached. A second connection is refused with 409, and a client that cannot keep up with the stream is dropped so it reopens onto a fresh replay.

Frames are SSE `data:` lines carrying one JSON object each, plus `: keepalive` comments. The stream uses bearer authentication, so clients need an SSE-capable `fetch` implementation rather than the browser's native `EventSource`, which cannot set this header. There are no SSE event IDs; reconnect by reopening the complete replay.

A JSON object whose type begins with an underscore is an ephemeral exec event. Apart from the server-owned `state` boundary, every other JSON object is a durable record the session holds. The boundary is `{"type":"state","working":true|false}`, with an `error` when a turn ended badly. See [`EXEC.md`](EXEC.md) for exec records, transient events, and permission shapes.

Text and reasoning deltas carry `seq`, a zero-based sequence shared by both kinds and restarted for each provider response. The server forwards them because the protocol is shared with the terminal, but a client owes them nothing: the page bundled here ignores deltas entirely and draws assistant text and reasoning only from the record that commits them.

`GET /session` may briefly return `503 Service Unavailable` while a live stream catches up with the session file; retry the connection.

## Actions

`POST /turn` starts a turn from a canonical user message and returns `202 Accepted`:

```json
{"type":"message","role":"user","content":[{"type":"text","text":"Review these changes"}]}
```

`POST /permission` answers the one pending request and returns `204 No Content`:

```json
{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}
```

`POST /cancel` has no body, stops the active turn, waits for it to settle, and returns `204 No Content`.

Actions do not otherwise name their target: there is one client, one turn, and one pending permission. A conflicting or missing target returns `409 Conflict`. A malformed object returns `400 Bad Request`, a body over 1 MiB returns `413 Request Entity Too Large`, invalid authentication returns `401 Unauthorized`, and shutdown may return `503 Service Unavailable`. Error responses are JSON objects of the form `{"error":"message"}`.

Action bodies are bounded JSON objects forwarded to exec unchanged. The server validates framing, while exec validates canonical message and permission fields. A turn outlives the `POST /turn` request and publishes all progress through `/session`.

The first shutdown signal stops new work and waits for an active turn to finish. A second signal forces shutdown. A turn waiting for permission may require the second signal after its client disconnects.

## Tests

`./server/test` runs the browser tests and then the Go tests. The browser tests load the page into a fresh realm over a small DOM stub, with no package manager and no dependencies.
