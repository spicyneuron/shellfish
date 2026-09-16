# Sessions

A Shellfish session is a JSONL file and the agent's only durable state. Clients replay it for presentation, and each `shellfish run` process owns one complete turn. There is no resident agent process.

## Contents

The first record is the session header: session metadata and a snapshot of the resolved runtime.

An optional `system` record follows with the materialized prompt used by provider requests. Startup context and turns follow as durable records.

Records after the header are append-only. Each complete provider response is one `assistant` record whose ordered content may include text, reasoning, and inert tool calls. Tool outcomes and durable hook context use distinct result types. Provider deltas, hook activity, permission prompts, and other live events are transient and never enter the file.

## Lifecycle

`shellfish create` resolves current configuration, materializes the system prompt, writes the initial records, and runs `session_start` hooks. See [`RUN.md`](RUN.md#session-creation-protocol) for the client protocol.

Opening an existing session uses its header and rejects ordinary runtime overrides. Interactive chat rebuilds the display from durable records and current presentation settings, then invokes one `shellfish run` process for each new turn.

`shellfish create --session-from PATH` derives a new, empty session from an existing runtime. It copies no conversation or startup context; it rematerializes the configured system components and runs startup hooks again.

## Runtime boundary

The header freezes resolved settings and manifest fields, not every external byte used by them. Executables, sandbox policy files, and credential values remain external.

Themes and global TUI preview limits are not part of the session. Interactive chat resolves them from current configuration whenever it opens a session.

The header is frozen against ambient configuration, but it is not immutable. Context-window discovery and hook-requested runtime updates may replace it after validation. Transcript records remain unchanged.

## Durability and recovery

Every durable prefix must be valid, including one left by an interrupted turn. Tool calls remain inert until the complete assistant response is validated and appended. A tool result exactly identifies and repeats the input of the call it settles.

The turn process closes interrupted work from what it knows: an active call is interrupted, later calls are cancelled, and completed outcomes are preserved. Reopening an unfinished session records unresolved calls as unknown outcomes, then closes the failed turn. Clients discard uncertain transient state and replay the session. See [`RUN.md`](RUN.md#completion-and-recovery) for recovery behavior.
