# Single-turn run and JSONL

`shellfish run` runs a single agent turn. A turn begins with one user message and may contain multiple provider requests, tool calls, permission decisions, and continuations requested by `stop` scripts.

`shellfish create` creates an idle session and prints its absolute path. Without `--session`, it uses current configuration. With `--session SESSION`, it derives the runtime from that session's frozen settings and rematerializes their system components. It does not copy messages, context, or the source system record. It runs the `session_start` scripts for the new session. `--path PATH` writes the new session to PATH instead of the state directory.

```sh
shellfish create
shellfish create --session path/to/session.jsonl
shellfish create --path ./project-session.jsonl
```

`shellfish --new [SESSION]` provides the same behavior and opens the new session in chat. Run does not create sessions; a turn requires one that already exists.

Ordinary run accepts prompt text and prints the final assistant text:

```sh
shellfish run "Review these changes"
printf '%s\n' "Review these changes" | shellfish run
```

`--jsonl` exposes the machine interface used by interactive chat and `shellfish-server`:

```sh
printf '%s\n' '{"type":"message","role":"user","content":[{"type":"text","text":"Review these changes"}]}' |
  shellfish run --jsonl --session path/to/session.jsonl
```

## Input

The first line on stdin must be exactly one canonical user message:

```json
{"type":"message","role":"user","content":[{"type":"text","text":"Review these changes"}]}
```

The object has exactly `type`, `role`, and `content`. `content` contains exactly one text block, and its text may not contain NUL. A prompt argument cannot be combined with `--jsonl`.

Stdin remains open for permission replies. When the turn emits a permission request, a client may write one matching response line:

```json
{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}
```

`decision` is `approve` or `deny`, and `id` must match the pending request. A client must preserve line framing and send no unrelated input. If no interactive client or `permission_request` script decides a sandbox bypass, the turn denies it.

## Read-only request composition

`shellfish build-request` and `shellfish send-request` expose the provider-request boundary without opening a durable turn. Both require `--session` and read the selected session without recovery or mutation.

`build-request` reads zero or more additional durable records as JSONL on stdin, validates them as a continuation of the selected session, and writes one canonical backend request. `--tools` accepts a JSON array of provider tool schemas and defaults to `[]`.

`send-request` reads one canonical backend request on stdin. It requires the request and transport options to match the session's frozen runtime, resolves the scoped backend credential, validates the adapter event stream, and writes one canonical assistant message.

Neither command runs hooks, executes tool calls, or persists its output. Provider tool schemas in a built request are inert. Diagnostics go to stderr and failures return nonzero.

```sh
printf '%s\n' '{"type":"message","role":"user","content":[{"type":"text","text":"Summarize this conversation"}]}' |
  shellfish build-request --session path/to/session.jsonl --tools '[]' |
  shellfish send-request --session path/to/session.jsonl
```

## Bundled compaction

The default harness implements compaction in its `user_prompt_submit` hook by composing `build-request` and `send-request` with tools disabled. `/compact` summarizes on demand. Automatic compaction runs when the most recent measured assistant usage reaches 80% of the frozen `context_window`; an unavailable window disables the automatic threshold.

Compaction creates a sibling child named with a `_compact` suffix without changing the source. The child retains the session header, system record, and `session_start` contexts, then replaces the conversation with one summary context. A successful hook requests a client handoff to the child. Automatic compaction passes the interrupted prompt as an editable draft rather than submitting it. Automatic failures are fail-open and submit the prompt to the source; explicit `/compact` failures stop that command and leave the source active.

## Output

Stdout contains one compact JSON object per line in source order. Objects fall into two classes:

- Types without a leading underscore are durable session records. The turn appends each record to the session before emitting it.
- Types beginning with `_` are transient events. They support live presentation and control and are never session records.

Durable records are:

- `session`: the resolved runtime header, emitted when a new session is created.
- `system`: the concatenated system components.
- `context`: model-visible hook script output.
- `message` with role `user`, `assistant`, or `tool_result`.

A sandboxed tool result includes `sandbox_denial_detected: true` when the tool exits non-zero and sandbox monitoring reports a denied action. The denial and non-zero exit are correlated signals; the denial is not necessarily the cause of the failure.

Transient events currently include:

| Type | Meaning |
| --- | --- |
| `_backend_request_start` | A provider request is starting. |
| `_assistant_delta` | Incremental assistant text for live presentation. |
| `_assistant_reasoning_delta` | Incremental reasoning text for live presentation. |
| `_turn_usage` | Token usage accumulated for the turn. |
| `_hook_display` | Ephemeral hook script stderr for a live notice. |
| `_tool_permission_request` | A sandbox bypass needs a client decision. |
| `_handoff` | A hook script asks a capable client to run `argv` after the turn exits cleanly. |
| `_session_update` | A hook-requested update or model-context discovery changed the session; `runtime` is the resulting resolved runtime. |
| `_turn_error` | The turn cannot start or complete the operation. |

Text and reasoning deltas carry a zero-based content `index` and a zero-based `seq`. The index identifies the block's position in the later assistant content. The sequence is shared by both delta types and restarted for each provider response, so it orders visible events independently of block identity. Deltas are previews only. Consumers should render committed assistant and reasoning content from the later durable assistant record. Clients should treat unknown transient types as unsupported protocol input and recover from the durable session rather than guessing their meaning.

Hook display events have the shape `{type:"_hook_display",hook,script,text,complete}`. The first newline-terminated stderr line is emitted with `complete:false` while the script runs. When the script exits, its full stderr replaces that notice with `complete:true`. A script that exits before writing a newline emits only the complete event. An interrupted invocation may end without a complete event, so clients must discard an incomplete notice when the turn stream fails, ends, or is replayed.

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

A nonzero exit means the operation failed or was interrupted. The turn emits `_turn_error` when JSONL output is available. After malformed output, disconnection, cancellation, or process failure, discard uncertain live state and replay the durable session.

If a provider fails or is cancelled after the turn accepted visible text or reasoning, cleanup makes a best-effort append of that content as a canonical assistant message with `stop: "length"`. A failure before visible content uses the ordinary interruption record. This recovery cannot guarantee persistence after `SIGKILL` or process crash.

Do not write presentation or lifecycle records into a session. Transcript records are append-only and owned by Shellfish. Custom clients submit turns through `shellfish run` and use the transcript only for replay and recovery. A hook-requested session update may atomically replace the runtime header.
