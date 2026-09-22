# Harnesses

A harness defines how Shellfish behaves as an agent. It combines tools, lifecycle hooks, sandbox policy, and turn limits around the shared execution loop. A profile selects a harness together with a backend, a system prompt, and model request settings.

The core owns event ordering, persistence, recovery, and cleanup. The harness supplies tools and workflow policy. Harnesses are frozen when a session is created, so changes affect new sessions rather than existing ones.

See [`CONFIG.md`](CONFIG.md) for composition, lookup, and the bundled coding harness. This document defines the executable component contracts.

## Shared contract

Tools, hooks, and backend adapters are executable component directories. Component references resolve before the session is created, and the resolved paths and manifests are frozen in its header.

| Component | Required files | Trust |
| --- | --- | --- |
| Tool | `run`, `manifest.json` or `manifest.jsonc`; `fence.jsonc` when sandboxed | Model-facing; optionally sandboxed |
| Hook | `run`; optional manifest | Trusted, user permissions |
| Backend adapter | `run`, manifest; optional `context_window` | Trusted, user permissions |

Scripts run from the session working directory. Shellfish starts each in an isolated process group, terminates ordinary descendants on completion or cancellation, and escalates from `TERM` to `KILL`. Components must finish their own subprocesses; daemonizing is unsupported.

Hook and tool stdout, stderr, and fd 3 share `max_capture_bytes`. Hooks fail when they exceed it. Tool control data must fit first; remaining stdout and stderr are tail-preserving and may be truncated. Raw captures are transient—only rendered text and accepted state records are durable.

### Environment

Manifests list environment variable names under `environment`. Exported values take precedence over `.env`; undeclared component credential names are removed before launch.

| Variable | Tool | Hook |
| --- | :---: | :---: |
| `SHELLFISH_SESSION` | ✓ | ✓ |
| `SHELLFISH_EXECUTABLE` | ✓ | ✓ |
| `SHELLFISH_CONFIG_DIR` | ✓ | ✓ |
| `SHELLFISH_MAX_CAPTURE_BYTES` | ✓ | ✓ |
| `SHELLFISH_MODEL` |  | ✓ |
| `SHELLFISH_MODE` |  | ✓ (`run`) |
| `SHELLFISH_VERBOSE` |  | ✓ (`0` or `1`) |
| `SHELLFISH_TURN_ID` |  | Turn hooks only |
| `SHELLFISH_TURN_STATE` |  | Turn hooks only |
| `TMPDIR`, `TMPPREFIX` | ✓ |  |

All tool calls in one turn share a private `TMPDIR`; Shellfish removes it during cleanup. Sandboxed tools start with a clean environment. Unsandboxed tools, hooks, and adapters inherit the filtered process environment plus their selected values.

### Rendering

Tool and hook manifests may define `render` templates:

| Field | When shown |
| --- | --- |
| `initial_user_text` | Activity before execution |
| `user_text` | Durable user-facing result |
| `model_text` | Durable model context |
| `permission_user_text` | Tool-only sandbox-bypass preview |
| `preview_lines` | `"full"` or a non-negative TUI line limit |

Templates perform one substitution pass. Available variables are `name`, `input`, `input.FIELD`, and—for result templates—`output.stdout`, `output.stderr`, and `output.exit_code`. Empty rendered text is omitted.

Hook defaults expose stderr to the user and stdout to the model. Tool defaults show the name and input, then return stdout and stderr to both. A manifest overrides only the fields it supplies.

### Durable state

Hooks and tools may write one JSON object to fd 3:

```json
{"state":[{"name":"example/status","value":{"ready":true}}]}
```

Names are at most 128 characters and match `^[A-Za-z0-9][A-Za-z0-9_.:/-]*$`. The latest exact name is effective; `null` clears it. Accepted state is appended before the component result. A component starting an untrusted child must close fd 3 so the child cannot forge state.

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
  "render": {"initial_user_text": "${name} ${input.path}"}
}
```

| Field | Requirement |
| --- | --- |
| `description` | Required nonempty model-facing description |
| `input_schema` | Required JSON Schema for an object |
| `sandbox` | Required boolean |
| `allow_sandbox_bypass` | Optional, default `false`; valid only when sandboxed |
| `environment` | Optional unique variable names |
| `render` | Optional template overrides |

Shellfish calls `run` with no arguments and one input object on stdin. Sandbox-bypass control fields are removed first. The tool must validate input before using it. A nonzero exit is a normal tool result and does not fail the turn.

The result repeats the exact call ID, name, and input and records an exit code. State is committed after normal execution and before the result, including for nonzero exits; interrupted execution commits no requested state.

If the model calls an undeclared tool, Shellfish records a rejected result with default rendering. Calls are processed in response order, and each complete result is persisted before the next call.

### Sandbox and permission

A tool is sandboxed only when both its manifest and harness enable sandboxing. Shellfish runs it under [`fence`](https://github.com/fencesandbox/fence) with its `fence.jsonc`; harness path grants extend that policy, but deny rules win. Otherwise it runs with user permissions.

For a sandboxed tool with `allow_sandbox_bypass: true`, Shellfish adds `request_sandbox_bypass` and `sandbox_bypass_reason` to the schema shown to the model. A requested bypass proceeds unsandboxed only when a `permission_request` hook or interactive client approves it. Otherwise the tool is not invoked and receives a denied result.

A detected sandbox denial on a nonzero tool exit adds an advisory `<sandbox_notice>` to model context; it does not assert that the denial caused the failure.

## Hooks

Hooks are ordered shell scripts bound to lifecycle points. They add context and workflow policy without changing the core agent loop. Bundled and custom hooks use the same process contract.

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

A hook manifest may select environment variables and rendering. Only `user_prompt_submit` supports selectors and help metadata:

```json
{
  "environment": ["HOOK_MODE"],
  "match": {"pattern": "^/review\\z"},
  "help": {"usage": "/review", "description": "Review changes"},
  "render": {"initial_user_text": "Checking the working tree"}
}
```

`match` is a jq-compatible regular expression. An executable named `match` beside `run` replaces it: the script receives the normal hook context, must write nothing, and selects on exit 0, skips on 1, and fails otherwise. Selection preserves configured order.

stdout, stderr, and fd 3 are bounded together. fd 3 must contain exactly one object when used. State and rendered hook output become durable in that order before the next component runs. A silent exit 0 creates no result record.

| Exit | Default action | Remaining chain |
| ---: | --- | --- |
| `0` | Perform | Run |
| `10` | Skip | Run |
| `11` | Skip | Halt |
| Other | Fail the operation | Halt |

Skipping is sticky: a later exit 0 does not restore the lifecycle's default action.

### Lifecycle reference

| Hook | argv | stdin | Exit 10 | Exit 11 / control |
| --- | --- | --- | --- | --- |
| `session_start` | — | Empty | Unsupported | Unsupported |
| `user_prompt_submit` | — | Exact prompt | Block; continue chain | Block; halt; optional handoff or session update |
| `permission_request` | `NAME ID` | Tool request | Deny; continue chain | Halt; required `allow` or `deny` decision |
| `pre_tool_use` | `NAME ID` | Tool request | Deny; continue chain | Deny; halt |
| `post_tool_use` | `NAME ID` | Tool response | Unsupported | Unsupported |
| `stop` | `ATTEMPT` | Final assistant text | Add feedback; continue inference and chain | Add feedback; continue inference; halt chain |

Exit 0 performs the named default: finish creation, submit the prompt, defer permission to a client, execute the tool, accept the tool result, or finish the turn. Without a capable client, deferred permission is denied.

Tool hooks receive canonical envelopes:

```json
{"turn_id":1,"tool_name":"shell","tool_use_id":"call_1","tool_input":{"command":"true"}}
```

`post_tool_use` receives the same fields plus:

```json
{"tool_response":{"stdout":"","stderr":"","exit_code":0}}
```

Every hook accepts `state` on fd 3. Hook-specific exit-11 controls are:

```json
{"action":"handoff","argv":["command","arg"]}
{"action":"allow"}
{"action":"deny","reason":"optional feedback"}
```

A handoff asks a capable client to run the complete `argv` after a clean turn exit. A session update has the shape `{"action":"session_update","runtime":RUNTIME}`, where `RUNTIME` is one complete valid runtime; Shellfish atomically replaces the header. `pre_tool_use` and `post_tool_use` cannot rewrite tool input or results. `permission_request` may only allow or deny a supported sandbox bypass.

## Backend adapters

A backend adapter translates between Shellfish's provider-neutral protocol and one inference provider. It owns request projection, transport, stream parsing, and provider-specific validation. The core assembles, persists, and recovers complete assistant responses.

An adapter manifest declares its default endpoint and environment:

```json
{"endpoint":"https://api.example.com/v1/messages","environment":["EXAMPLE_API_KEY"]}
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

An optional executable `context_window` receives the same request and selected environment before the first provider request when capacity is absent. It returns:

```json
{"context_window":200000}
```

The value must be positive. Failure or any other output means metadata is unavailable and does not fail inference. Discovery must not make a generation request.
