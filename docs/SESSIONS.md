# Sessions

A Shellfish session is just a JSONL file. This is the authoritative state of the agent: clients replay it for presentation, and each `shellfish run` process reads then appends to it. There is no other durable agent state and no resident agent process.

## Contents

The first record is the session header. It contains the working directory, creation time, and resolved runtime: backend, tools, hooks, limits, sandbox policy, etc. It's a self-contained snapshot that's bound to that session.

An optional `system` record follows. It contains the materialized prompt used in provider requests; a session with an empty prompt has no system record. Keeping the prompt separate from its component paths lets a session use stable instructions while retaining the inputs needed to derive another session.

Startup context and turns follow as durable records. Records after the header are append-only. Provider deltas, hook activity, permission prompts, and other live client events are transient and never enter the file.

## Lifecycle

`shellfish create` resolves the current configuration into a runtime, reads the selected system components, creates the header and optional system record, and runs `session_start` hooks. See [`RUN.md`](RUN.md#session-creation-protocol) for the command and client protocol.

Repeated `--system` and `--system-file` options replace the materialized prompt for that creation. They do not replace the system component paths in the header.

Opening an existing session uses its header and rejects ordinary runtime overrides. Interactive chat rebuilds the display from durable records and current presentation settings, then invokes one `shellfish run` process for each new turn.

`shellfish create --session-from PATH` derives a new, empty session from an existing runtime. It copies no messages or startup context; it re-reads the stored system component paths and runs startup hooks again. Later system-file changes therefore affect derived sessions, not the source session's prompt.

## Runtime boundary

The header freezes runtime selection, not every external byte used by that runtime. Resolved settings and manifest fields are stored directly, while executables, sandbox policy files, and credential values remain external.

Themes and TUI preview limits are not part of the session. Interactive chat resolves them from current configuration whenever it opens a session.

The header is frozen against ambient configuration, but it is not immutable. Context-window discovery and hook-requested runtime updates may replace it after validation. Transcript records remain unchanged.

## Durability and recovery

Every durable prefix must be valid, including one left by an interrupted turn. Tool calls remain inert until the complete assistant response is validated and appended. After interruption or uncertain live output, clients discard their transient state and replay the session. See [`RUN.md`](RUN.md#completion-and-recovery) for recovery behavior.
