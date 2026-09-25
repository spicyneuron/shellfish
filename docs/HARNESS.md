# Harnesses

A harness defines how Shellfish behaves as an agent. It combines tools, lifecycle hooks, sandbox policy, and turn limits around the shared execution loop. A profile holds one harness together with a backend, a system prompt, and model request settings.

The core owns event ordering, persistence, recovery, and cleanup. The harness supplies tools and workflow policy. A session freezes its component lists and settings when it is created; the component files themselves are read on each run.

See [`CONFIG.md`](CONFIG.md) for composition, lookup, and the bundled coding harness. This document defines the executable component contracts.

## Shared contract

Tools and backend adapters are executable component directories; a hook is one executable file. Component references resolve before the session is created, and the resolved paths are frozen in its header. Manifests and scripts are read on each run.

| Component | Required files | Trust |
| --- | --- | --- |
| Tool | `run`, `manifest.json` or `manifest.jsonc`; `fence.jsonc` when sandboxed | Model-facing; optionally sandboxed |
| Hook | The executable itself | Trusted, user permissions |
| Backend adapter | `run`, manifest; optional `context_window` | Trusted, user permissions |

Scripts run from the session working directory. Shellfish starts each in an isolated process group, terminates ordinary descendants on completion or cancellation, and escalates from `TERM` to `KILL`. Components must finish their own subprocesses; daemonizing is unsupported.

Raw captures are transient—only settled text and accepted state records are durable.

### Environment

Hooks and adapters inherit the process environment and receive every value in `.env`. Tools receive only the `.env` names listed under `environment` in their manifest. Exported values take precedence over `.env`.

| Variable | Tool | Hook |
| --- | :---: | :---: |
| `SHELLFISH_SESSION` | ✓ | ✓ |
| `SHELLFISH_EXECUTABLE` | ✓ | ✓ |
| `SHELLFISH_CONFIG_DIR` | ✓ | ✓ |
| `SHELLFISH_MAX_CAPTURE_BYTES` | ✓ | ✓ |
| `SHELLFISH_SHARE_DIR` | ✓ | ✓ |
| `SHELLFISH_MODEL` |  | ✓ |
| `SHELLFISH_MODE` |  | ✓ (`run`) |
| `SHELLFISH_VERBOSE` |  | ✓ (`0` or `1`) |
| `SHELLFISH_TURN_ID` |  | Turn hooks only |
| `SHELLFISH_TURN_STATE` |  | Turn hooks only |
| `TMPDIR`, `TMPPREFIX` | ✓ |  |

`SHELLFISH_SHARE_DIR` is the installed bundled `share/` root, so scripts can call its parts, such as `$SHELLFISH_SHARE_DIR/hooks/review`.

Tools use the host's `TMPDIR`, or `/tmp` when it is unset, and receive a `TMPPREFIX` beneath it. Sandboxed tools may read and write the platform temp directories as baseline temporary storage; tools own their cleanup. Sandboxed tools otherwise start with a clean environment plus their declared names. Unsandboxed tools inherit the process environment plus their declared names.

### Output

Hooks and tools stream JSON objects to fd 3 while they run, one per line:

| Key | Meaning |
| --- | --- |
| `user_text` | Replaces the live section's user-facing text; the component now owns it |
| `model_text` | Replaces the live section's model context; the component now owns it |
| `finalize` | `true` settles the live section now and opens an empty one; hooks only |
| `user_preview_lines` | `"full"` or a TUI line limit for the live section and the result it settles |
| `state` | State records, such as `[{"name":"example/status","value":{"ready":true}}]` |
| `action` | A hook's lifecycle decision; see [Hooks](#hooks) |

User text streams as live progress. At exit, each field the component did not write is filled from captured output; the component sections below say who sees what. A field it wrote keeps exactly that text, so a component that shows progress must write its final text too. A section with neither text creates no result. `max_capture_bytes` bounds each line and that fallback output. An invalid line fails the execution.

State names are at most 128 characters and match `^[A-Za-z0-9][A-Za-z0-9_.:/-]*$`. The latest exact name is effective; `null` clears it. Accepted state is appended before the result it accompanies. A component starting an untrusted child must close fd 3 so the child cannot forge state.

## Tools

A tool manifest defines its model-facing schema and execution policy:

```json
{
  "description": "Read one project file.",
  "input_schema": {
    "type": "object",
    "additionalProperties": false,
    "required": ["path"],
    "properties": {"path": {"type": "string", "minLength": 1}}
  },
  "sandbox": true,
  "allow_sandbox_bypass": true,
  "environment": ["TOOL_SETTING"],
  "user_text": "${name} ${input.path}"
}
```

| Field | Requirement |
| --- | --- |
| `description` | Required nonempty model-facing description |
| `input_schema` | Required JSON Schema for an object |
| `sandbox` | Required boolean |
| `allow_sandbox_bypass` | Optional, default `false`; valid only when sandboxed |
| `environment` | Optional unique variable names |
| `user_text` | Optional user text shown before the tool's output; default `${name} ${input}` |
| `user_permission` | Optional sandbox-bypass prompt text; default `${input}` |

Templates perform one substitution pass over `name`, `input`, and `input.FIELD` for a declared property.

Shellfish calls `run` with no arguments and one input object on stdin. Sandbox-bypass control fields are removed first. The tool must validate input before using it. A nonzero exit is a normal tool result and does not fail the turn.

A call settles exactly once, at exit. State from each valid line is committed as it arrives, including if the tool later fails or is interrupted. Unless the tool writes its own, the user sees the rendered `user_text` followed by stdout and stderr, and the model sees stdout and stderr; that output keeps its tail when it exceeds `max_capture_bytes`. A line beyond the limit fails the call. Tools take no `action`; interruption settles a rejected result instead of the tool's output.

The result repeats the exact call ID, name, and input and records an exit code. If the model calls an undeclared tool, Shellfish records a rejected result. Calls are processed in response order, and each complete result is persisted before the next call.

### Sandbox and permission

A tool is sandboxed only when both its manifest and harness enable sandboxing. Shellfish runs it under [`fence`](https://github.com/fencesandbox/fence), found on `PATH` when the tool runs, with its `fence.jsonc`; platform temp access and harness path grants extend that policy, but deny rules win. Otherwise it runs with user permissions.

For a sandboxed tool with `allow_sandbox_bypass: true`, Shellfish adds `request_sandbox_bypass` and `sandbox_bypass_reason` to the schema shown to the model. A requested bypass proceeds unsandboxed only when a `permission_request` hook or interactive client approves it. Otherwise the tool is not invoked and receives a denied result.

A detected sandbox denial on a nonzero tool exit adds an advisory `<sandbox_notice>` to model context; it does not assert that the denial caused the failure.

## Hooks

Hooks are executables bound to lifecycle points. They add context and workflow policy without changing the core agent loop. Bundled and custom hooks use the same process contract.

```text
create session
    session_start
begin turn
    user_prompt_submit
append user
repeat:
    append assistant
    if tool calls:
        for each call:
            pre_tool_use
            permission_request when execution needs approval
            execute or deny tool
            post_tool_use
        continue
    stop
    if completion allowed: finish turn
```

Each lifecycle runs its configured hooks in order, each as a separate process with the original stdin and arguments. A hook without an action defers to the next. A successful action ends the list; if every hook defers, the lifecycle takes its no-action outcome. Only hooks named in the resolved profile run; see [`CONFIG.md`](CONFIG.md#harness).

### Hook output

A hook writes the [shared output](#output). State and each finalized section become durable as the line arrives, so an interrupted or failed hook keeps what it already settled. At exit 0, the last section settles; unless the hook writes its own, the user sees stdout and stderr and the model sees stdout. A hook fails when its fallback output exceeds `max_capture_bytes`. Any nonzero exit fails the operation, with stderr in the diagnostic.

Model text from one lifecycle reaches the model grouped in `<hook name="LIFECYCLE">`, each result inserted verbatim. Bundled hooks wrap theirs in `<context script="NAME">`.

A hook changes the lifecycle's outcome by writing an `action` line to fd 3. The last action from that hook wins and applies only after exit 0. Without an action, the next hook runs.

### Lifecycle reference

| Hook | argv | stdin | Actions | No action |
| --- | --- | --- | --- | --- |
| `session_start` | — | Empty | None | Finish creation |
| `user_prompt_submit` | — | Exact prompt | `block`, `handoff`, `session_update` | Submit the prompt |
| `permission_request` | `NAME ID` | Tool request | `allow`, `deny` | Defer to a capable client, otherwise deny |
| `pre_tool_use` | `NAME ID` | Tool request | `deny` | Execute the tool |
| `post_tool_use` | `NAME ID` | Tool response | None | Accept the result |
| `stop` | `ATTEMPT` | Final assistant text | `continue` | Finish the turn |

Tool hooks receive canonical envelopes:

```json
{"turn_id":1,"tool_name":"shell","tool_use_id":"call_1","tool_input":{"command":"true"}}
```

`post_tool_use` receives the same fields plus:

```json
{"tool_response":{"stdout":"","stderr":"","exit_code":0}}
```

Actions take these shapes:

```json
{"action":"block"}
{"action":"handoff","argv":["command","arg"]}
{"action":"session_update","profile":PROFILE}
{"action":"allow"}
{"action":"deny","reason":"optional feedback"}
{"action":"continue"}
```

A block ends the turn without submitting the prompt. A handoff asks a capable client to run the complete `argv` after a clean turn exit. A session update's `PROFILE` is one complete session profile, as stored in the header; Shellfish atomically replaces it. A `pre_tool_use` deny reason becomes the refused tool result. A `stop` continue requires settled model text, then continues inference with it. `pre_tool_use` and `post_tool_use` cannot rewrite tool input or results. `permission_request` may only allow or deny a supported sandbox bypass.

## Backend adapters

A backend adapter translates between Shellfish's provider-neutral protocol and one inference provider. It owns request projection, transport, stream parsing, and provider-specific validation. The core assembles, persists, and recovers complete assistant responses.

An adapter manifest declares its default endpoint:

```json
{"endpoint":"https://api.example.com/v1/messages"}
```

Shellfish starts `run` once per provider request with one object on stdin:

```json
{
  "format_version": 1,
  "system": "Materialized system text",
  "messages": [],
  "tools": [],
  "options": {"request": {"model": "provider-model"}},
  "transport": {
    "endpoint": "https://api.example.com/v1/messages",
    "insecure_tls": false,
    "http_timeout": 120,
    "http_stall": 30
  }
}
```

`messages` contains provider-neutral conversation records in transcript order. `tools` contains model-facing tool definitions. `options.request` contains common and provider-specific settings; unrelated fields pass through. `transport` is authoritative for the exchange.

Bundled adapters normalize token limits in this order: `max_output_tokens`, `max_completion_tokens`, `max_tokens`. `reasoning_effort` overrides `reasoning.effort`, and `response_schema` replaces the provider-native structured-output setting. The Codex adapter omits output limits because its endpoint rejects them.

### Response stream

The adapter writes one normalized JSON event per line:

| Event | Required payload |
| --- | --- |
| `_assistant_message_delta` | `index`, append-only `text` |
| `_assistant_reasoning_delta` | `index`, append-only `text` |
| `_assistant_reasoning_opaque` | `index`, complete `opaque` object |
| `_assistant_tool_call_delta` | `index` and at least one of `id`, `name`, append-only raw JSON `input` |
| `_turn_usage` | Non-negative `input_tokens`, `output_tokens`; optional cached/reasoning counts |
| `_assistant_end` | `stop`: `end`, `tool_calls`, or `length` |

Indexes are non-negative and define final content order. One index cannot change content type. Tool IDs and names cannot change once set; complete tool input must decode to an object, and IDs must be unique within the response. Opaque reasoning preserves provider data needed by later requests and must repeat identically for one index.

Event objects use these exact normalized fields; provider-native correlation needed only during parsing remains adapter-local.

The latest usage event wins; cached tokens cannot exceed input tokens. Exactly one `_assistant_end` must be final: `tool_calls` requires complete calls, `end` forbids calls, and `length` discards calls. The adapter must then exit 0. Stderr is failure diagnostics, never stream data.

The core validates and assembles the complete response before persisting it or permitting tool execution. A nonzero exit or invalid stream fails the request.

### Context-window discovery

An optional executable `context_window` receives the same request and environment before the first provider request when capacity is absent. It returns:

```json
{"context_window":200000}
```

The value must be positive. Failure or any other output means metadata is unavailable and does not fail inference. Discovery must not make a generation request.
