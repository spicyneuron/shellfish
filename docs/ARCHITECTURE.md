# Architecture

Shellfish starts from the heretical premise that AI agents are actually simple: an append-only log, an HTTP client, some filesystem operations, and a tiny state machine on top. A perfect fit for plain shell processes and text protocols.

```text
                        ┌────────────────┐
client ─ user prompt ─▶ │  read session  │
   ▲                    │        │       │
   │                    │        ▼       │───▶ backend adapter
   └────── events ──────│   agent loop   │───▶ hook scripts
                        │        │       │───▶ tool scripts
                        │        ▼       │
                        │ append session │
                        └────────────────┘
```

## The transcript is the state

A session JSONL file is the agent's only durable state. The first row freezes runtime settings. Every record after it belongs to one append-only transcript. A complete assistant response keeps its ordered text, reasoning, and inert tool calls together; later result records settle those calls exactly.

One session reader defines record validity and ordering, then derives pending work and provider messages from that transcript. Recovery and request construction do not maintain competing session models.

## A turn is the unit of execution

One `shellfish run` process owns the complete transition from user message to final response. There is no resident agent process.

## The harness is just shell scripts

The core guarantees ordering, validation, persistence, recovery, and cleanup. Everything around it is configurable shell scripts:

- **Backends** make API requests to inference providers.
- **Tools** let the model act.
- **Hooks** add context and workflow policy at lifecycle boundaries.

Hooks and backends are trusted and run with your permissions; tools can be sandboxed. Each can provide a JSON manifest to configure environment access and other settings.

## Clients invoke turns

Clients submit prompts, render events, and replay the transcript. They own interaction and presentation, but rely on `shellfish run` for the agent loop and state.
