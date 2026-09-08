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
| `_notice` | Transient hook activity and stderr, using the shared notice format below. |
| `state`, `context` | Durable output from the successful `session_start` chain. |
| `_session_created` | `path`, after startup hooks finish successfully. |

Creation writes the header and optional system record before running hooks. A successful hook chain appends and emits state followed by context. An empty chain emits only the preparation and creation events. On failure, Shellfish removes the new session, reports diagnostics, exits nonzero, and emits no creation event. Clients must not submit a turn until creation exits successfully.

As in a turn, `SIGUSR1` is the client's cancellation signal, aimed at the creating process alone so it can stop a running hook script itself. Cancelled creation exits nonzero and removes the new session.

`--system TEXT` and `--system-file PATH` replace the configured or copied system prompt. Both flags are repeatable and may be mixed; their contents have trailing newlines stripped and are joined in command-line order with a blank line.

Chat and `shellfish run` use an existing session with `--session PATH`. Otherwise they create one through `shellfish create`, accepting `--session-from` and `--session-out`. Neither creation flag can be combined with `--session`.

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

`send-request` reads one canonical backend request on stdin. It requires the request and transport options to match the session's frozen runtime, resolves the backend's selected environment, validates the adapter event stream, and writes one canonical assistant message.

Neither command runs hooks, executes tool calls, or persists its output. Provider tool schemas in a built request are inert. Diagnostics go to stderr and failures return nonzero.

```sh
printf '%s\n' '{"type":"message","role":"user","content":[{"type":"text","text":"Summarize this conversation"}]}' |
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
- `message` with role `user`, `assistant`, or `tool_result`. An assistant record carries the turn's token usage when the provider reported it.
- `state`: `{type:"state",name,value}`, model-invisible durable named state.
- `turn_error`: `{type:"turn_error",message}`, the failure that ended an accepted turn without an assistant answer. It is never sent to a provider.

A state record has exactly those three fields. Its name is an opaque string of at most 128 ASCII characters matching `^[A-Za-z0-9][A-Za-z0-9_.:/-]*$`. Its value may be any JSON value. The latest record for an exact name is effective, and `null` means the name has no effective value at that transcript position. State records do not affect conversation sequencing and are omitted from provider requests.

Hook state is emitted before context or another durable hook outcome. Tool state is emitted after normal tool completion and before its durable result, including for a nonzero tool exit. Interrupted tools and tool orchestration failures emit no tool state.

A sandboxed tool result includes `sandbox_denial_detected: true` when the tool exits non-zero and sandbox monitoring reports a denied action. The denial and non-zero exit are correlated signals; the denial is not necessarily the cause of the failure.

Transient events currently include:

| Type | Meaning |
| --- | --- |
| `_backend_request_start` | A provider request is starting. |
| `_assistant_delta` | Incremental assistant text for live presentation. |
| `_assistant_reasoning_delta` | Incremental reasoning text for live presentation. |
| `_assistant_settle` | Marks visible assistant content ready to settle before a tool call. |
| `_notice` | A user-facing notice: hook script output, or a failure before the turn was accepted. |
| `_tool_permission_request` | A sandbox bypass needs a client decision. |
| `_handoff` | A hook script asks a capable client to run `argv` after the turn exits cleanly. |
| `_session_update` | A hook-requested update or model-context discovery changed the session; `runtime` is the resulting resolved runtime. |

Text and reasoning deltas carry a zero-based content `index` and a zero-based `seq`. The index identifies the block's position in the later assistant content. The sequence is shared by both delta types and restarted for each provider response, so it orders visible events independently of block identity. `_assistant_settle` is emitted when the first tool-call update after visible deltas arrives. It lets clients settle that visible content, but does not expose the partial tool call; the call remains unavailable until its durable assistant record. Deltas are previews only. Consumers should render committed assistant and reasoning content from the later durable assistant record. Clients should treat unknown transient types as unsupported protocol input and recover from the durable session rather than guessing their meaning.

Notices have the shape `{type:"_notice",level,title,source,text,complete}`. The level is `info` or `error`. The source attributes the notice, and is empty when there is no attribution. Hook scripts opt into display through stderr: the first newline-terminated line opens an informational notice titled with the script path and attributed to the hook, with `complete:false`. The script's full stderr replaces it with `complete:true` after capture checks succeed. A script that writes no newline emits only the complete notice. Silent hooks emit no activity notices. An interrupted invocation or rejected capture may end without completion, so clients must discard an incomplete notice when the stream fails, ends, or is replayed. Failures are complete error notices.

Hook stdout is not attached to notices. Its lifecycle policy determines whether it becomes durable context after the complete hook chain succeeds.

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

A nonzero exit means the operation failed or was interrupted. A failure after the user record is committed is appended and emitted as a durable `turn_error`; its message is the user-facing outcome. `SIGINT` and the client's `SIGUSR1` cancellation signal record `Cancelled.`, while other handled signals record `Turn interrupted.` An earlier failure is reported as an error `_notice` when JSONL output is available. After malformed output, disconnection, cancellation, or process failure, discard uncertain live state and replay the durable session.

If a provider fails or is cancelled after the turn accepted visible text or reasoning, cleanup makes a best-effort append of that content as a canonical assistant message with `stop: "length"`. Otherwise the user message remains unanswered. Cleanup appends error results for any durable tool calls that did not finish. This recovery cannot guarantee persistence after `SIGKILL` or process crash.

Do not write presentation or lifecycle records into a session. Transcript records are append-only and owned by Shellfish. Custom clients submit turns through `shellfish run` and use the transcript only for replay and recovery. A hook-requested session update may atomically replace the runtime header.
