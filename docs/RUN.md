# Single-turn run and JSONL

`shellfish run` runs a single agent turn. A turn begins with one user message and may contain multiple provider requests, tool calls, permission decisions, and continuations requested by `stop` scripts.

Ordinary mode accepts prompt text and prints the final assistant text:

```sh
shellfish run "Review these changes"
```

`--jsonl` exposes the machine interface used by interactive chat and `shellfish-server`:

```sh
printf '%s\n' '{"type":"user","content":[{"type":"text","text":"Review these changes"}]}' |
  shellfish run --jsonl --session path/to/session.jsonl
```

`shellfish run --jsonl --session-create` creates an idle session and exits after startup hooks. `--session-from PATH` derives one from an existing session's runtime, while `--session-out PATH` selects its destination. See [`SESSIONS.md`](SESSIONS.md) for session semantics.

## Reading a session

`shellfish load --session PATH` is the read-only session boundary. It validates the complete durable prefix, then writes one transient path event followed by the canonical header and durable records in file order:

```json
{"type":"_session_load","path":"/absolute/path/session.jsonl"}
{"type":"session","format_version":1,"cwd":"/project","created":"...","runtime":{"backend":{},"harness":{},"profile":{}}}
{"type":"system","content":"..."}
```

Nothing is emitted until the whole prefix validates, and nothing is ever written back. A final unterminated line is an interrupted append and is ignored; the newline-terminated prefix before it must be valid. A structurally valid unfinished turn loads as it stands, because ordinary [recovery](#completion-and-recovery) belongs to the next `run`.

## Session creation protocol

`shellfish run --jsonl --session-create` streams the creation protocol. No creation mode prints a session path:

| Type | Fields and meaning |
| --- | --- |
| `_session_load` and initial records | The created session path, followed by its header and optional system record. |
| `_hook_activity` | A selected startup component's configured initial user text, or the empty clear event its silent completion sends. |
| `state` and `hook_result` | Durable startup records, emitted immediately after they are appended. |

Creation publishes the session and its system context before running startup hooks. Hooks then run in configured order, with each durable result following its live activity. A failed or cancelled startup reports the failure on stderr and retains the valid session prefix and any completed hook results. Clients must wait for successful process exit before submitting a turn.

`--system` and `--system-file` replace the configured system prompt for that creation. Chat and `run` accept the same creation options when they are not opening an existing `--session`.

## Input

The first line on stdin must be exactly one canonical user message:

```json
{"type":"user","content":[{"type":"text","text":"Review these changes"}]}
```

The object contains exactly one text block. A prompt argument cannot be combined with `--jsonl`.

Stdin remains open for permission replies. When the turn emits a permission request, a client may write one matching response line:

```json
{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}
```

`decision` is `approve` or `deny`, and `id` must match the pending request. Clients must preserve line framing and send no unrelated input. Without a client or hook decision, the turn denies the bypass.

## Read-only backend request

`shellfish backend-request` reads one complete transcript on stdin, invokes its frozen backend, and writes one canonical assistant record:

It supplies no tools, runs no hooks, and persists nothing.

```sh
cat path/to/session.jsonl | shellfish backend-request
```

## Output

Stdout contains one compact JSON object per line in source order. Objects fall into two classes:

- Types without a leading underscore are durable session records. The turn appends each record to the session before emitting it.
- Types beginning with `_` are transient events. They support live presentation and control and are never session records.

| Durable type | Meaning |
| --- | --- |
| `session` | Resolved runtime header |
| `system` | Materialized system prompt |
| `hook_result` | Attributed model or user context from a hook |
| `user` | User prompt |
| `assistant` | Complete provider response and optional usage |
| `tool_result` | Completed, denied, or interrupted call result |
| `state` | Model-invisible durable named state |
| `error` | User-facing failure or cancellation; ignored by model requests |

For an exact state name, the latest value is effective and `null` clears it. State does not affect conversation sequencing or provider requests.

Transient events currently include:

| Type | Meaning |
| --- | --- |
| `_assistant_start` | A provider request is starting. |
| `_assistant_message_delta` | Incremental assistant text for live presentation. |
| `_assistant_reasoning_delta` | Incremental reasoning text for live presentation. |
| `_assistant_tool_call_delta` | Incremental tool-call fragments, for ordering only. |
| `_assistant_reasoning_opaque` | Provider reasoning data for later requests; nothing to present. |
| `_turn_usage` | The provider's latest token usage for this response. |
| `_assistant_end` | The response is complete; `stop` is its reason. It precedes the durable assistant record. |
| `_hook_activity` | A selected ordinary hook component's configured initial user text, or an empty clear event. |
| `_tool_activity` | A validated tool call is being processed. |
| `_tool_permission_request` | A sandbox bypass needs a client decision. |
| `_handoff` | A hook script asks a capable client to run `argv` after the turn exits cleanly. |
| `_session_update` | A hook-requested update or model-context discovery changed the session; `runtime` is the resulting resolved runtime. |

`_assistant_start` and `_assistant_end` bound one provider response. Indexed deltas are previews of the later durable assistant record. Partial tool calls are inert and must never be executed. On unknown or malformed transient input, clients recover by replaying the durable session rather than guessing.

A permission request has this shape:

```json
{
  "type": "_tool_permission_request",
  "id": "permission_1",
  "reason": "Why the tool requested the bypass",
  "tool": {"name": "shell", "input": {"command": "..."}}
}
```

## Completion and recovery

A zero exit means the operation completed cleanly, including a hook that deliberately blocked submission or requested a handoff. A tool may return a nonzero result without failing the turn itself.

After a run fails or is cancelled against a writable session, Shellfish appends a durable `error`. It first preserves any recoverable partial assistant response and settles calls still owned by that process: a known outcome is preserved, an active call is interrupted, and later calls are cancelled. Provider requests derive each call and result from this validated transcript. Errors are replayed to users but omitted from provider requests.

Abrupt process or machine loss may leave a tool-calling assistant response without settled results. The next turn records each unresolved call as an unknown outcome and closes the interrupted turn before accepting new work.

After any uncertain live outcome, clients discard transient state and replay the session. They never append presentation or lifecycle events themselves; transcript mutation belongs to Shellfish.
