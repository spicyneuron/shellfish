# Single-turn run and JSONL

`shellfish run` runs a single agent turn. A turn begins with one user message and may contain multiple provider requests, tool calls, permission decisions, and continuations requested by `stop` scripts.

`shellfish create` creates an idle session from current configuration and prints its absolute path. `--session-from PATH` copies an existing session's frozen runtime and system record, without messages or context. Creation runs the new session's `session_start` scripts. `--session-out PATH` selects the destination instead of the state directory.

```sh
shellfish create
shellfish create --session-from path/to/session.jsonl
shellfish create --session-out ./project-session.jsonl
```

`shellfish create --jsonl` streams startup events instead of printing a path:

| Type | Fields and meaning |
| --- | --- |
| `_session_prepare` | `path` and the durable header and optional system record, before hooks run. |
| `_hook_start`, `_hook_end` | One selected startup component's live lifecycle. |
| `state`, `context` | Durable output from each validated `session_start` component. |
| `_session_created` | `path`, after startup hooks finish successfully. |

Creation writes the header and optional system record before running hooks. Each component opens, runs, validates, appends and emits state followed by context, then closes before the next component starts. An empty chain emits only the preparation and creation events. On startup failure, Shellfish attempts to remove the new session, reports diagnostics, exits nonzero, and emits no creation event. Cleanup is best effort; a valid published session is not removed merely because writing its events or final path to stdout fails. Clients must not submit a turn until creation exits successfully.

As in a turn, `SIGUSR1` is the client's cancellation signal, aimed at the creating process alone so it can stop a running hook script itself. Cancelled creation exits nonzero and attempts the same best-effort cleanup as other startup failures; abrupt termination can leave the published session behind.

`--system TEXT` and `--system-file PATH` replace the configured or copied system prompt. Both flags are repeatable and may be mixed; their contents have trailing newlines stripped and are joined in command-line order with a blank line.

Chat and `shellfish run` use an existing session with `--session PATH`. Otherwise they create one through `shellfish create`, accepting `--session-from` and `--session-out`. Neither creation flag can be combined with `--session`.

## Canonical transcript installation

`shellfish install-session --session-out PATH` reads one canonical JSONL transcript from stdin and prints the installed absolute path. It preserves the supplied bytes, runs no hooks, and does not resolve configuration. The transcript needs a canonical header and valid record sequencing, but may end at any point a durable session can, including an unanswered user message or unfinished tool calls. The next `shellfish run` closes such a turn through ordinary [recovery](#completion-and-recovery).

Installation refuses an existing file, directory, or symlink and exits with status 3, so a caller that names its own children can retry under another name. It publishes the validated transcript atomically with mode 0600. Destination naming and transcript derivation belong to the calling feature.

Ordinary run accepts prompt text and prints the final assistant text:

```sh
shellfish run "Review these changes"
printf '%s\n' "Review these changes" | shellfish run
```

`--jsonl` exposes the machine interface used by interactive chat and `shellfish-server`:

```sh
printf '%s\n' '{"type":"user","content":[{"type":"text","text":"Review these changes"}]}' |
  shellfish run --jsonl --session path/to/session.jsonl
```

## Input

The first line on stdin must be exactly one canonical user message:

```json
{"type":"user","content":[{"type":"text","text":"Review these changes"}]}
```

The object has exactly `type` and `content`. `content` contains exactly one text block, and its text may not contain NUL. A prompt argument cannot be combined with `--jsonl`.

Stdin remains open for permission replies. When the turn emits a permission request, a client may write one matching response line:

```json
{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}
```

`decision` is `approve` or `deny`, and `id` must match the pending request. A client must preserve line framing and send no unrelated input. If no interactive client or `permission_request` script decides a sandbox bypass, the turn denies it.

## Read-only request composition

`shellfish build-request` and `shellfish send-request` expose the provider-request boundary without opening a durable turn. Both require `--session` and read the selected session without recovery or mutation.

`build-request` reads zero or more additional durable records as JSONL on stdin, validates them as a continuation of the selected session, and writes one canonical backend request. `--tools` accepts a JSON array of provider tool schemas and defaults to `[]`.

`send-request` reads one canonical backend request on stdin. It requires the request and transport options to match the session's frozen runtime, resolves the backend's selected environment, validates the adapter event stream, and writes one canonical assistant message.

Neither command runs hooks, executes tool calls, or persists its output. Provider tool schemas in a built request are inert. Diagnostics go to stderr and failures return nonzero.

```sh
printf '%s\n' '{"type":"user","content":[{"type":"text","text":"Summarize this conversation"}]}' |
  shellfish build-request --session path/to/session.jsonl --tools '[]' |
  shellfish send-request --session path/to/session.jsonl
```

## Output

Stdout contains one compact JSON object per line in source order. Objects fall into two classes:

- Types without a leading underscore are durable session records. The turn appends each record to the session before emitting it.
- Types beginning with `_` are transient events. They support live presentation and control and are never session records.

Durable records are:

- `session`: the resolved runtime header, emitted when a new session is created.
- `system`: the concatenated system components.
- `context`: model-visible hook script output.
- `user`: one user prompt.
- `assistant`: one provider response, including token usage when reported.
- `tool_call`: `{type:"tool_call",id,name,input}`, one call the assistant requested, appended when it reaches its execution point.
- `tool_result`: one completed, denied, or interrupted tool call.
- `state`: `{type:"state",name,value}`, model-invisible durable named state.
- `turn_error`: `{type:"turn_error",message}`, the failure that ended an accepted turn without an assistant answer. It is never sent to a provider.

A state record has exactly those three fields. Its name is an opaque string of at most 128 ASCII characters matching `^[A-Za-z0-9][A-Za-z0-9_.:/-]*$`. Its value may be any JSON value. The latest record for an exact name is effective, and `null` means the name has no effective value at that transcript position. State records do not affect conversation sequencing and are omitted from provider requests.

Hook state is emitted before context or another durable hook outcome. Tool state is emitted after normal tool completion and before its durable result, including for a nonzero tool exit. Interrupted tools and tool orchestration failures emit no tool state.

A sandboxed tool result includes `sandbox_denial_detected: true` when the tool exits non-zero and sandbox monitoring reports a denied action. The denial and non-zero exit are correlated signals; the denial is not necessarily the cause of the failure.

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
| `_hook_start` | A selected ordinary hook component is about to run. |
| `_hook_end` | The current ordinary hook component validated or failed. |
| `_notice` | Unattributed user-facing information or failure. |
| `_tool_permission_request` | A sandbox bypass needs a client decision. |
| `_handoff` | A hook script asks a capable client to run `argv` after the turn exits cleanly. |
| `_session_update` | A hook-requested update or model-context discovery changed the session; `runtime` is the resulting resolved runtime. |

`_assistant_start` opens a response and `_assistant_end` closes it. Between them the turn forwards the adapter's events verbatim, in stream order. Deltas carry a zero-based content `index` identifying the block's position in the later assistant content.

Deltas are previews only. Tool-call `input` fragments are raw text, not parsed JSON, and a client must never render or execute a partial call. Consumers should render committed assistant and reasoning content from the durable assistant record, and each call from its own `tool_call` record. Clients should treat unknown transient types as unsupported protocol input and recover from the durable session rather than guessing their meaning.

`_hook_start` has `{type,hook,script,text}`, where `text` is the component's manifest display string. Every selected ordinary component emits a start, including a component with an empty display string. Its validated state and context records follow immediately. `_hook_end` has `{type,text,error}`. Nonempty stderr supplies its text; otherwise stdout does. Empty text removes the live presentation. `error` is true when a failure belongs to that component. The end event relies on stream order and carries no correlation ID. `permission_request` components emit neither lifecycle event nor successful stderr; their failures use the ordinary turn-failure path.

Notices have the shape `{type:"_notice",level,title,source,text,complete}`. They are one-shot events after this change: core notices have no component source and are complete. Hook activity never uses `_notice`.

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

A successful process exit means the single-turn operation completed cleanly. This includes a `user_prompt_submit` script that deliberately blocks submission or requests a handoff. Tool commands may return nonzero results without making the turn itself fail.

A nonzero exit means the operation failed or was interrupted. A failure after the user record is committed is appended and emitted as a durable `turn_error`; its message is the user-facing outcome. `SIGINT` and the client's `SIGUSR1` cancellation signal record `Cancelled.`, while other handled signals record `Turn interrupted.` A failure attributed to an ordinary hook component is also reported by `_hook_end`; permission hooks emit no display event. An otherwise unpersisted failure uses an error `_notice` when JSONL output is available. After malformed output, disconnection, cancellation, or process failure, discard uncertain live state and replay the durable session.

If a provider fails or is cancelled after the turn accepted visible text or reasoning, cleanup makes a best-effort append of that content as a canonical assistant message with `stop: "length"`. Otherwise the user message remains unanswered. Cleanup closes a recorded call that did not finish, and appends a `tool_call` and a cancelled result for each call the response requested that never started. A process killed outright loses the calls it had not yet recorded. This recovery cannot guarantee persistence after `SIGKILL` or process crash.

Do not write presentation or lifecycle records into a session. Transcript records are append-only and owned by Shellfish. Custom clients submit turns through `shellfish run` and use the transcript only for replay and recovery. A hook-requested session update may atomically replace the runtime header.
