# Architecture

Shellfish starts from the heretical premise that AI agents are actually simple: an append-only log, an HTTP client, some filesystem operations, and a tiny state machine on top. A perfect fit for plain shell processes and text protocols.

```text
                        ┌────────────────┐
client ─ user prompt ─▶ │  read session  │
   ▲                    │        │       │
   │                    │        ▼       │───▶ provider
   └────── events ──────│   agent loop   │───▶ hook scripts
                        │        │       │───▶ tool scripts
                        │        ▼       │
                        │ append session │
                        └────────────────┘
```

## The transcript is the state

A session JSONL file is the agent's only durable state. Its first line is a header and every later line is one record:

```text
{"type":"session","format_version":1,"cwd":"~/project","created":"...","profile":{...},"model":{...}}
{"type":"user","content":[{"type":"text","text":"Fix the bug"}]}
{"type":"assistant","stop":"end","content":[{"type":"text","text":"Done."}]}
```

The header freezes the resolved profile and model, each in its config file's shape, so together they resolve to the same header. The profile holds the system prompt text, the tool, command, and hook lists, and the merged sandbox setting and grants. The model holds the merged provider, endpoint, and request settings. System prompt files are frozen as their text, like model and sandbox files; executable components, manifests, and policies remain live. Credentials, environment settings such as turn limits, and presentation settings remain external.

Header paths use `@` for the bundled root, `~/` for HOME, or `/` for fixed absolute locations, so a session survives upgrades and moves with its home. If the project moves independently of HOME, update the header cwd.

| Durable record | Role |
| --- | --- |
| `hook_result` | Lifecycle hook output |
| `user` | User message |
| `assistant` | Complete assistant response with text, reasoning, and tool calls |
| `tool_result` | The exact call identity and input plus its settled result |
| `state_update` | Model-invisible named state update; the latest exact name wins and `null` clears it |
| `error` | Durable user-facing failure or cancellation, omitted from provider requests |

Provider deltas, hook activity, permission requests, and presentation state are transient. Clients may display them but never write them to the transcript.

One session reader defines record validity and ordering, then derives pending work and provider messages from that transcript. Recovery and request construction do not maintain competing session models.

## A turn is the unit of execution

One `shellfish run` process owns the complete transition from user message to final response. A session lock prevents overlapping turns and releases when the process exits. There is no resident agent process.

On macOS and Linux, `shellfish run --background` starts an isolated one-turn process and returns the absolute session path once it starts. The acknowledgement does not mean the prompt was persisted or the turn completed; inspect the transcript for durable progress. Background output is not streamed.

```text
open and recover session
  -> run a command or submission hooks
  -> append user
  -> request and append assistant
  -> execute and append tool results while requested
  -> run stop hooks
  -> clean up
```

The process reduces the transcript to its next step before each one instead of tracking its own position. It appends each canonical record before emitting it to a client. Tool calls stay inert until the provider's complete response has been validated and persisted.

Cancellation keeps any streamed text or reasoning, settles calls whose outcomes are known, marks active or later calls interrupted or cancelled, and appends an error. A write failure stops further mutation.

## The harness is just shell scripts

The core guarantees ordering, validation, persistence, recovery, and cleanup. Everything around it is configurable shell scripts:

- **Providers** make inference API requests.
- **Tools** let the model act.
- **Commands** handle `/NAME` prompts instead of submitting them.
- **Hooks** add context and workflow policy at lifecycle boundaries.

Commands, hooks, and providers are trusted and run with your permissions. Tools can be sandboxed. See [Component trust](COMPONENTS.md#environment-and-trust) for credential access and trust rules.

| Owner | Responsibility |
| --- | --- |
| Core | Canonical records, event order, session mutation, recovery, permissions, and cleanup |
| Provider | Request translation, transport, stream parsing, and API-specific validation |
| Command | One user-requested action in place of a prompt |
| Hook | Context or policy before and after core operations |
| Tool | One model-requested action and optional durable state request |

Hooks and tools communicate through JSON, stdout, stderr, and a small control channel. Providers emit normalized JSON events. Components do not receive a mutable session object. See [`COMPONENTS.md`](COMPONENTS.md) for writing tools, commands, hooks, and providers.

## Clients invoke turns

Clients submit prompts and render what they receive. They own interaction and presentation, but rely on `shellfish run` for the agent loop and state. A client replays the durable transcript for history and reads live events from the turn it invoked; both use one presentation vocabulary. Clients never append to a session, recover one, or reinterpret its profile or model.

Types without a leading underscore are durable records already appended by the turn owner. Types beginning with `_` are transient. If a live outcome becomes uncertain, the client discards its transient view and replays the file instead of guessing.
