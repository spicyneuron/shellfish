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

A session JSONL file is the agent's only durable state. Its first line is a header and every later line is one record:

```text
{"type":"session","format_version":1,"cwd":"~/project","created":"...","profile":{...}}
{"type":"system","content":"..."}
{"type":"user","content":[{"type":"text","text":"Fix the bug"}]}
{"type":"assistant","stop":"end","content":[{"type":"text","text":"Done."}]}
```

The header freezes the resolved profile: the model and request settings, backend, the tool, system, and hook lists, limits, and sandbox grants. It is itself a complete profile. System file text is materialized into the session's system record at creation; executable components, manifests, and policies remain live. Credential values and presentation settings remain external.

Header paths use `@KIND/NAME` for bundled components, `~/` for HOME, or `/` for fixed absolute locations, so a session survives upgrades and moves with its home. If the project moves independently of HOME, update the header cwd.

| Durable record | Role |
| --- | --- |
| `system` | System prompt |
| `hook_result` | Lifecycle hook output |
| `user` | User message |
| `assistant` | Complete assistant response with text, reasoning, and tool calls |
| `tool_result` | The exact call identity and input plus its settled result |
| `state` | Model-invisible named state; the latest exact name wins and `null` clears it |
| `error` | Durable user-facing failure or cancellation, omitted from provider requests |

Provider deltas, hook activity, permission requests, usage previews, and presentation state are transient. Clients may display them but never write them to the transcript.

One session reader defines record validity and ordering, then derives pending work and provider messages from that transcript. Recovery and request construction do not maintain competing session models.

## A turn is the unit of execution

One `shellfish run` process owns the complete transition from user message to final response. There is no resident agent process.

On macOS and Linux, `shellfish run --background` starts an isolated one-turn process and returns the absolute session path once it starts. The acknowledgement does not mean the prompt was persisted or the turn completed; inspect the transcript for durable progress. Background output is not streamed.

```text
open and recover session
  -> run submission hooks
  -> append user
  -> request and append assistant
  -> execute and append tool results while requested
  -> run stop hooks
  -> clean up
```

The process reads the transcript again at each consuming boundary instead of retaining a second session representation. It appends each canonical record before emitting it to a client. A backend's partial tool-call fragments remain inert until the complete assistant response has been assembled, validated, and persisted.

Cancellation preserves any valid partial text or reasoning, settles calls whose outcomes are known, marks active or later calls interrupted or cancelled, and appends an error. A write failure stops further mutation.

## The harness is just shell scripts

The core guarantees ordering, validation, persistence, recovery, and cleanup. Everything around it is configurable shell scripts:

- **Backends** make API requests to inference providers.
- **Tools** let the model act.
- **Hooks** add context and workflow policy at lifecycle boundaries.

Hooks and backends are trusted, run with your permissions, and receive every value in `.env`; tools can be sandboxed and receive only the `.env` names their manifest declares. Tools and backends describe other settings in a JSON manifest.

| Owner | Responsibility |
| --- | --- |
| Core | Canonical records, event order, session mutation, recovery, permissions, and cleanup |
| Backend adapter | Provider request translation, transport, stream parsing, and provider-specific validation |
| Hook | Context or policy before and after core operations |
| Tool | One model-requested action and optional durable state request |

Hooks and tools communicate through JSON, stdout, stderr, and a small control channel; backend adapters emit normalized JSON events. Components do not receive a mutable session object. See [`HARNESS.md`](HARNESS.md) for their contracts.

## Clients invoke turns

Clients submit prompts and render what they receive. They own interaction and presentation, but rely on `shellfish run` for the agent loop and state. A client replays the durable transcript for history and reads live events from the turn it invoked; both use one presentation vocabulary. Clients never append to a session, recover one, or reinterpret its profile.

Types without a leading underscore are durable records already appended by the turn owner. Types beginning with `_` are transient. If a live outcome becomes uncertain, the client discards its transient view and replays the file instead of guessing.
