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

Every request carries `Authorization: Bearer CODE`, where the code is the six digits printed at startup. The page itself is served without it. After it is entered, the page keeps the code only in `sessionStorage`, so reloads in that tab reconnect automatically and closing the tab clears it. `detach session` clears the stored code and reloads the page. Its content security policy allows only its own three assets, so a script injected into a transcript has nowhere to run and nowhere to report.

The bind address defaults to loopback. Anything else warns at startup and should sit behind TLS.

## The session stream

`GET /session` is the client's entire view of the session and its only recovery. A connection replays the durable JSONL as it stands, sends a `state` frame that closes the replay, and then forwards what the child emits. Reopening it is how a client recovers from a disconnect, an unexpected frame, missed work, or an uncertain ending; the server never reconciles anything on the client's behalf.

Only one client may be attached. A second connection is refused with 409, and a client that cannot keep up with the stream is dropped so it reopens onto a fresh replay.

Frames are SSE `data:` lines carrying one JSON object each, plus `: keepalive` comments. A type beginning with an underscore is ephemeral presentation; everything else is a record the session holds, byte for byte as it appears on disk. `state` is the server's own frame: `{"type":"state","working":true|false}`, with an `error` when a turn ended badly.

Text and reasoning deltas carry `seq`, a zero-based sequence shared by both kinds and restarted for each provider response. The server forwards them because the protocol is shared with the terminal, but a client owes them nothing: the page bundled here ignores deltas entirely and draws assistant text and reasoning only from the record that commits them.

A child appends a record to the session before it emits that record, so for an instant the file can be ahead of the stream. A connection that lands in that instant is refused with 503 rather than reconciled, and succeeds when the client retries.

## Actions

`POST /turn` starts a turn from a canonical user message. `POST /cancel` stops whatever turn is running. `POST /permission` answers whatever request is pending. None of them name their target: there is one client, one turn, and one pending request, and the server refuses with 409 when the target does not exist.

Bodies are JSON objects, bounded in size, forwarded to the child unchanged. Whether a body is a canonical message or a canonical permission response is exec's judgement, not the server's. A cancelled turn is given time to commit what it has: `SIGTERM` to exec alone, then the process group, and the response waits for the child to settle.

## Tests

`./server/test` runs the browser tests and then the Go tests. The browser tests load the page into a fresh realm over a small DOM stub, with no package manager and no dependencies.
