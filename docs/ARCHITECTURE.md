# Architecture

Shellfish is the brainchild of my grudge against bloated modern software, plus a large chunk of expiring AI subscription tokens. It leans into simplicity as a constraint: shell scripts, processes, and text. Just as Ken Thompson intended.

## The transcript is the state

A session JSONL file is the authoritative state of the agent. Transcript records after its header are append-only and durable. Provider deltas, permission prompts, hook script display output, and other transient events are not.

Clients attach to a session and consume the same event stream. Durable records provide history they can replay, while transient events provide live interaction around it. A client can use either without becoming another owner of the state.

The session header consolidates the resolved settings required to run the agent: backend, harness, model request, tools, hooks, limits, sandbox policy. A session carries the runtime configuration needed to continue it instead of being reinterpreted through the current profile on every turn. Credentials and presentation settings remain external. A hook-requested session update may atomically replace the header; submitted model turns never rewrite it.

The bundled compaction hook preserves that append-only boundary by creating a child session rather than rewriting its source. The child keeps the frozen runtime and startup context and replaces the conversation with a model-produced continuation summary. A capable handoff client opens the child and, for automatic compaction, restores the interrupted prompt as an editable draft. A client that cannot follow the handoff remains on the source, whose original history is unchanged.

## A turn is the unit of execution

A turn is one transition of the agent state machine. It begins with a user message, then repeats a small loop:

1. Turn the durable transcript into a provider request.
2. Append the assistant response.
3. If the response contains tool calls, run them and append their results.
4. Send another provider request until there are no more tool calls.

One `shellfish run` process owns the entire transition, including cleanup. There is no resident agent process and no ownership to coordinate across requests or tools.

Backend adapters translate provider responses into indexed text, reasoning, opaque reasoning, and tool-call updates followed by one response-end event. The exec framework validates and accumulates that normalized stream into the canonical assistant message. Adapters retain only provider-specific parsing, correlation, and protocol validation. Tool calls remain inert until the complete response has been assembled, validated, and appended.

## Clients invoke turns

Terminal chat, `shellfish-server`, and any other integrations all use the same boundary. A client submits one user message to `shellfish run`, consumes its JSONL, and answers permission requests over stdin when it can. The process exits when the turn is complete.

Clients do not embed the agent loop or maintain their own copy of session state. They invoke turns and present the results.

`shellfish build-request` and `shellfish send-request` expose the narrower provider boundary for read-only composition. They project or execute a request against a session's frozen runtime without mutating the transcript. `exec` remains the owner of durable turns, hook execution, tool execution, and recovery.

## Harnesses bind scripts to the lifecycle

The turn loop is deliberately generic. A harness combines tools, limits, sandbox policy, and shell scripts bound to lifecycle hooks. The default coding behavior is assembled this way rather than built into `shellfish run`.

Project discovery, slash commands, permission policy, tool review, and stop-time continuation are all harness behavior. The core still owns event ordering, validation, persistence, recovery, and cleanup. Hook scripts can influence a turn at defined points, but they do not redefine the state machine.

Tools may run inside the configured sandbox. Hook scripts and backend adapters are trusted programs that run with the user's permissions. The scoped API key is passed only to the backend adapter.
