# Single-turn exec and JSONL

`shellfish exec` runs a single agent turn. A turn begins with one user message and may contain multiple provider requests, tool calls, permission decisions, and continuations requested by `stop` scripts.

`exec --new [SESSION]` creates an idle session and prints its absolute path. Without `SESSION`, it uses current configuration. With `SESSION`, it copies that session's frozen settings and rematerializes their system hook components. It does not copy messages, context, or the source system record. It runs the `session_start` scripts for the new session.

```sh
shellfish exec --new
shellfish exec --new path/to/session.jsonl
```

`shellfish --new [SESSION]` provides the same behavior and opens the new session in chat.

Ordinary exec accepts prompt text and prints the final assistant text:

```sh
shellfish exec "Review these changes"
printf '%s\n' "Review these changes" | shellfish exec
```

`--jsonl` exposes the machine interface used by interactive chat and `shellfish-server`:

```sh
printf '%s\n' '{"type":"message","role":"user","content":[{"type":"text","text":"Review these changes"}]}' |
  shellfish exec --jsonl --session path/to/session.jsonl
```

## Input

The first line on stdin must be exactly one canonical user message:

```json
{"type":"message","role":"user","content":[{"type":"text","text":"Review these changes"}]}
```

The object has exactly `type`, `role`, and `content`. `content` contains exactly one text block, and its text may not contain NUL. A prompt argument cannot be combined with `--jsonl`.

Stdin remains open for permission replies. When exec emits a permission request, a client may write one matching response line:

```json
{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}
```

`decision` is `approve` or `deny`, and `id` must match the pending request. A client must preserve line framing and send no unrelated input. If no interactive client or `permission_request` script decides a sandbox bypass, exec denies it.

## Output

Stdout contains one compact JSON object per line in source order. Objects fall into two classes:

- Types without a leading underscore are durable session records. Exec appends each record to the session before emitting it.
- Types beginning with `_` are transient events. They support live presentation and control and are never session records.

Durable records are:

- `session`: the resolved runtime header, emitted when a new session is created.
- `system`: the materialized system hook output.
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
| `_hook_display` | Ephemeral hook script stderr for the user. |
| `_tool_permission_request` | A sandbox bypass needs a client decision. |
| `_handoff` | A hook script asks a capable client to run `argv` after exec exits cleanly. |
| `_session_update` | A hook-requested session update completed; `runtime` is the resulting resolved runtime. |
| `_exec_error` | Exec cannot start or complete the operation. |

Text and reasoning deltas carry a zero-based content `index` and a zero-based `seq`. The index identifies the block's position in the later assistant content. The sequence is shared by both delta types and restarted for each provider response, so it orders visible events independently of block identity. Deltas are previews only. Consumers should render committed assistant and reasoning content from the later durable assistant record. Clients should treat unknown transient types as unsupported protocol input and recover from the durable session rather than guessing their meaning.

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

A successful process exit means the single-turn operation completed cleanly. This includes a `user_prompt_submit` script that deliberately blocks submission or requests a handoff. Tool commands may return nonzero results without making exec itself fail.

A nonzero exec exit means the operation failed or was interrupted. Exec emits `_exec_error` when JSONL output is available. After malformed output, disconnection, cancellation, or process failure, discard uncertain live state and replay the durable session.

If a provider fails or is cancelled after exec accepted visible text or reasoning, cleanup makes a best-effort append of that content as a canonical assistant message with `stop: "length"`. A failure before visible content uses the ordinary interruption record. This recovery cannot guarantee persistence after `SIGKILL` or process crash.

Do not write presentation or lifecycle records into a session. Transcript records are append-only and owned by Shellfish. Custom clients submit turns through exec and use the transcript only for replay and recovery. A hook-requested session update may atomically replace the runtime header under the session lock.
