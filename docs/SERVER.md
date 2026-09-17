# shellfish-server

`shellfish-server` exposes one Shellfish session to one browser. It runs every turn through `shellfish run --jsonl` and replays the durable session transcript directly.

Install the optional server with Go:

```sh
go install github.com/spicyneuron/shellfish/shellfish-server@latest
```

## Run the server

Run `shellfish-server` from the project directory. Without `--session`, it creates a session through `shellfish run --jsonl --session-create` using the same runtime options as a new chat:

```sh
shellfish-server --profile work --model MODEL
```

To serve an existing session:

```sh
shellfish-server --session path/to/session.jsonl
```

An existing session already contains its resolved runtime, so `--session` cannot be combined with runtime overrides. Server-specific options include:

| Option | Meaning |
| --- | --- |
| `--session PATH` | Serve an existing session instead of creating one. |
| `--bind ADDRESS` | Set the listening address. Defaults to `127.0.0.1:9158`. |
| `--shellfish PATH` | Select the Shellfish executable used to create sessions and run turns. |

When serving an existing session, the server requires its working directory to match the session's recorded project directory.

## Access

Startup prints the server URL and a six-digit access code. Enter that code in the browser. Every API request requires it as `Authorization: Bearer CODE`; protect it like a password.

The server binds to loopback by default. A non-loopback address produces a warning and should be placed behind TLS. A reverse proxy must preserve the `Authorization` header, disable buffering for `/session`, and allow long-lived SSE responses.

## Session stream

The browser opens an authenticated `GET /session`. Each connection receives:

1. The complete durable transcript as it currently stands.
2. A server-owned `_session_status` frame marking the end of replay.
3. Records and transient events from the active turn.

The `_session_status` frame has this shape:

```json
{"type":"_session_status","working":true}
```

`working` reports whether a turn is active. A failed turn may add an `error` field when no durable record can carry the failure.

Reopening `/session` starts a complete replay rather than resuming from an event ID. Clients should retry temporary unavailability.

Only one browser may be attached. A second connection is rejected, and a client that falls behind is disconnected so it can reopen onto a fresh replay.

Frames are SSE `data:` lines containing one JSON object each, plus `: keepalive` comments. Authentication requires an SSE-capable `fetch` implementation because the browser's native `EventSource` cannot set the authorization header.

Types beginning with an underscore are transient; other turn objects are durable records. The browser renders durable assistant records rather than their preceding deltas and ignores model-invisible state.

The server relays `_handoff` events but does not execute them or switch sessions. The browser therefore remains attached to the source session.

## Actions

Every action requires bearer authentication.

`POST /turn` starts a turn from one canonical user message:

```json
{"type":"user","content":[{"type":"text","text":"Review these changes"}]}
```

The request returns before the turn finishes; progress appears on `/session`.

`POST /permission` answers the pending permission request:

```json
{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}
```

`POST /cancel` has no body. It stops the active turn and waits for cleanup.

There is at most one active turn and one pending permission request, so actions need no separate session or turn identifier. Conflicting actions are rejected.

## Shutdown

The first shutdown signal stops accepting work and gives an active turn time to finish. A turn waiting for permission is cancelled immediately. A second signal or the shutdown timeout cancels remaining work.
