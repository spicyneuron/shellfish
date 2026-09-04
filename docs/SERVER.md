# shellfish-server

`shellfish-server` exposes one Shellfish session to one browser. It runs every turn through `shellfish exec --jsonl`, so terminal chat, the server, and other clients all use the same agent loop and durable transcript.

Install the optional server with Go:

```sh
go install github.com/spicyneuron/shellfish/shellfish-server@latest
```

To build a local copy from the Shellfish repository instead:

```sh
go build -o bin/shellfish-server ./shellfish-server
```

## Run the server

Run `shellfish-server` from the project directory the session belongs to. Without `--session`, it creates an idle session by forwarding its remaining options to `shellfish create`:

```sh
shellfish-server --profile work --model MODEL
```

This accepts the runtime options resolved by `shellfish config`, including `--profile`, `--backend`, `--model`, `--request`, `--config`, `--sandbox-read`, and `--sandbox-write`.

To serve an existing session:

```sh
shellfish-server --session path/to/session.jsonl
```

An existing session already contains its resolved runtime, so `--session` cannot be combined with forwarded Shellfish options. It can still be combined with the server's own options:

| Option | Meaning |
| --- | --- |
| `--session PATH` | Serve an existing session instead of creating one. |
| `--bind ADDRESS` | Set the listening address. Defaults to `127.0.0.1:9158`. |
| `--shellfish PATH` | Select the Shellfish executable used to create sessions and run turns. |
| `-h`, `--help` | Show server usage and exit. |
| `--version` | Show the server version and exit. |

The server refuses an existing session whose recorded working directory differs from the directory where the server was started.

## Access

Startup prints the server URL and a six-digit access code. Enter the displayed code in the browser. The displayed hyphen is not part of the credential, so `123-456` becomes `123456`.

The page and its static assets are public, but every API request requires `Authorization: Bearer CODE`. The page keeps the code in `sessionStorage`, which survives reloads in that tab and is cleared when the tab closes. `detach session` clears it immediately.

The page escapes transcript content, and its content security policy limits resources to bundled same-origin assets. These are defense-in-depth controls, not a substitute for protecting the bearer code and transport.

The server binds to loopback by default. A non-loopback address produces a warning and should be placed behind TLS. A reverse proxy must preserve the `Authorization` header, disable buffering for `/session`, and allow long-lived SSE responses.

## Session stream

The browser opens an authenticated `GET /session`. Each connection receives:

1. The complete durable transcript as it currently stands.
2. A server-owned `state` frame marking the end of replay.
3. Records and transient events from the active turn.

The state frame has this shape:

```json
{"type":"state","working":true}
```

`working` reports whether a turn is active. The live state frame that ends a failed turn also carries an `error` field.

Reopening `/session` is the only recovery mechanism. It starts another complete replay rather than resuming from an event ID. The endpoint may briefly return `503 Service Unavailable` while a live stream catches up with the session file. Clients should retry.

Only one browser may be attached. A second connection receives `409 Conflict`. A client that falls behind is disconnected so it can reopen onto a fresh replay.

Frames are SSE `data:` lines containing one JSON object each, plus `: keepalive` comments. Authentication requires an SSE-capable `fetch` implementation because the browser's native `EventSource` cannot set the authorization header.

Types beginning with an underscore are transient exec events. Other exec objects are durable session records. The server-owned `state` frame is the one exception. Text and reasoning deltas share a zero-based `seq` that restarts for each provider response. The bundled browser ignores those deltas and renders the later durable assistant record.

The bundled browser replaces the current incomplete `_hook_display` notice with its completed text, leaving the completed notice visible. A turn end, stream failure, or replay discards any incomplete hook notice with the rest of the uncertain transient state.

The server relays `_handoff` events but does not execute their argv or switch sessions. The bundled browser reports the unsupported handoff. If argv includes `--draft`, it restores that value into an empty prompt editor; if the editor already contains newer text, it preserves that text and displays the handoff draft separately. The browser therefore remains attached to the source session after commands such as `/new`, `/fork`, `/resume`, and `/compact`.

## Actions

Every action requires bearer authentication.

`POST /turn` accepts one canonical user message and returns `202 Accepted`:

```json
{"type":"message","role":"user","content":[{"type":"text","text":"Review these changes"}]}
```

The turn continues after the request returns. Its progress appears on `/session`.

`POST /permission` answers the pending permission request and returns `204 No Content`:

```json
{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}
```

`POST /cancel` has no body. It stops the active turn, waits for cleanup, and returns `204 No Content`.

There is at most one active turn and one pending permission request, so actions do not carry a separate session or turn identifier. A conflicting or missing target returns `409 Conflict`.

The `/turn` and `/permission` bodies must be JSON objects no larger than 1 MiB. The server validates size and framing, while exec validates message and permission fields. Malformed input returns `400 Bad Request`, oversized input returns `413 Request Entity Too Large`, invalid authentication returns `401 Unauthorized`, and shutdown may return `503 Service Unavailable`. Error bodies have the form `{"error":"message"}`.

## Shutdown

The first shutdown signal stops accepting work and gives an active turn up to ten seconds to finish. A turn waiting for permission is cancelled immediately because its browser is disconnected. A second signal or the timeout cancels any other active turn.

## Tests

`./tests/run server` runs the browser and Go tests. The browser tests use a small DOM stub with no package manager or dependencies.
