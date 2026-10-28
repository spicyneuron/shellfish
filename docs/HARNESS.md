# Harnesses

A harness defines how Shellfish behaves as an agent. It combines tools and lifecycle hooks around the shared execution loop. A profile selects one harness together with system prompts and sandbox files. The model is selected separately.

The core owns event ordering, persistence, recovery, and cleanup. The harness supplies tools and workflow policy. A session freezes its component lists and settings when it is created; the component files themselves are read on each run.

See [`CONFIG.md`](CONFIG.md) for selection, lookup, settings, and the bundled harness. This document defines the executable component contracts.

## Shared contract

Tools, hooks, and backend adapters are executable component directories. References resolve before session creation and are frozen in its header. Manifests and scripts are read on each invocation.

Every component requires an executable `run`. Configuration lives in an optional `manifest.json` or `manifest.jsonc`, with an absent manifest treated as `{}`. Each role validates the settings it needs.

| Component | Additional requirements | Trust |
| --- | --- | --- |
| Tool | Model-facing metadata and execution policy, `fence.jsonc` when sandboxed | Model-facing, optionally sandboxed |
| Hook | None | Trusted, user permissions |
| Backend adapter | Endpoint from a model file or manifest, optional `context_window` executable | Trusted, user permissions |

Scripts run from the session working directory. Shellfish starts each in an isolated process group, terminates ordinary descendants on completion or cancellation, and escalates from `TERM` to `KILL`. Components must finish their own subprocesses; daemonizing is unsupported.

Raw captures and live progress are transient. Only settled text and accepted state updates are durable. Replay uses stored text, never manifests.

### Environment

Hooks and adapters inherit the process environment and receive every value in `.env`. Tools receive only the names listed under `environment` in their manifest. Exported values take precedence over `.env`, and both remain external. A component reads its own settings from these variables.

| Variable | Tool | Hook |
| --- | :---: | :---: |
| `SHELLFISH_SESSION` | ✓ | ✓ |
| `SHELLFISH_EXECUTABLE` | ✓ | ✓ |
| `SHELLFISH_DIR` | ✓ | ✓ |
| `SHELLFISH_MAX_CAPTURE_BYTES` | ✓ | ✓ |
| `SHELLFISH_SHARE_DIR` | ✓ | ✓ |
| `SHELLFISH_MODEL` |  | ✓ |
| `SHELLFISH_MODE` |  | ✓ (`run`) |
| `SHELLFISH_VERBOSE` |  | ✓ (`0` or `1`) |
| `SHELLFISH_TURN_ID` |  | Turn hooks only |
| `SHELLFISH_TURN_STATE` |  | Turn hooks only |
| `TMPDIR`, `TMPPREFIX` | ✓ |  |

`SHELLFISH_SHARE_DIR` is the installed bundled `share/` root, so scripts can call its parts, such as `$SHELLFISH_SHARE_DIR/hooks/review/run`.

Tools use the host's `TMPDIR`, or `/tmp` when it is unset, and receive a `TMPPREFIX` beneath it. Sandboxed tools may read and write the platform temp directories as baseline temporary storage; tools own their cleanup. Sandboxed tools otherwise start with a clean environment plus their declared names. Unsandboxed tools inherit the process environment plus their declared names.

### Channels

Hooks and tools have one channel per audience:

| Channel | Audience | Contents |
| --- | --- | --- |
| stdout | Model | Model text, stored as written |
| stderr | User | Text shown only through the `user_text` template |
| fd 3 | Shellfish | Newline-delimited JSON control lines |

A component that writes nothing on stdout gives the model nothing. Hooks that add context wrap their own model text, as the bundled `<context script="NAME">` blocks do. Tools report errors on stdout so the model sees them. Stdout and stderr each keep their tail behind an `[output truncated]` marker when they exceed `SHELLFISH_MAX_CAPTURE_BYTES`. A manifest's `max_capture_bytes` overrides that limit, with a minimum of `64` bytes.

Control lines accept `state_update`, such as `{"state_update":[{"name":"example/status","value":{"ready":true}}]}`. Each valid line's updates are durable immediately, even if the process later fails or is interrupted. Names are at most 128 characters and match `^[A-Za-z0-9][A-Za-z0-9_.:/-]*$`. The latest exact name is effective, and `null` clears it. Hooks also write lifecycle [actions](#hooks) here. Invalid or oversized control lines fail execution. A component starting an untrusted child must close fd 3.

### Presentation

A manifest's optional `user_text` is the component's one display template. It may use `${input}`, `${input.FIELD}` for a declared tool input property, `${output.stdout}`, and `${output.stderr}`. Strings insert literally, other values insert as JSON, and missing values insert empty. A component without `user_text`, or whose template renders empty, shows nothing.

The template renders while the component runs with empty output, and once more when it settles. Only the settled text is stored. A call that is refused, skipped, or interrupted renders its reason as `${output.stderr}`, and Shellfish gives the model that reason as the result. Every tool call receives a result. A hook result is stored only when it has text.

The first line of the rendered text is its header, and `user_preview_lines`, a line count or `"full"`, collapses the rest. Otherwise the client's preview limit applies. A tool that ran outside its sandbox is marked `[unsandboxed]` whatever its template says.

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
  "user_text": "Read ${input.path}\n${output.stdout}"
}
```

| Field | Requirement |
| --- | --- |
| `description` | Required nonempty model-facing description |
| `input_schema` | Required JSON Schema for an object |
| `sandbox` | Required boolean |
| `allow_sandbox_bypass` | Optional, default `false`; valid only when sandboxed |
| `environment` | Optional unique variable names |
| `user_text` | Optional [presentation](#presentation) template |

Shellfish calls `run` with no arguments and one input object on stdin. Sandbox-bypass control fields are removed first. The tool must validate input before using it. A nonzero exit is a normal tool result and does not fail the turn.

Tools take no lifecycle action. Interruption settles a rejected result instead of the tool's output.

The result repeats the exact call ID, name, and input and records an exit code. If the model calls an undeclared tool, Shellfish records a rejected result. Calls are processed in response order, and each complete result is persisted before the next call.

### Sandbox and permission

A tool is sandboxed only when both its manifest and the session enable sandboxing. Shellfish runs it under [`fence`](https://github.com/fencesandbox/fence), found on `PATH` when the tool runs, with its `fence.jsonc`; platform temp access and session grants extend that policy, but deny rules win. Otherwise it runs with user permissions.

For a sandboxed tool with `allow_sandbox_bypass: true`, Shellfish adds `request_sandbox_bypass` and `sandbox_bypass_reason` to the schema shown to the model. A requested bypass proceeds unsandboxed only when a `permission_request` hook or interactive client approves it. Otherwise the tool is not invoked. The prompt shows the tool name and its raw input, never the template.

A detected sandbox denial on a nonzero tool exit adds an advisory `<sandbox_notice>` to captured stdout. It does not assert that the denial caused the failure.

## Hooks

Hooks are components bound to lifecycle points. A hook's manifest names its lifecycle with `on`, such as `{"on":"stop"}`, read like the rest of the manifest on each run. Manifests also accept `user_text`, `user_preview_lines`, `max_capture_bytes`, and an optional `match.pattern` jq regular expression. A nonmatching hook is skipped without running its script or producing a result. Without `match`, the hook runs for every invocation. Each script still decides what to do with matching input.

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
            append tool result
            post_tool_use
        continue
    stop
    if completion allowed: finish turn
```

Each lifecycle runs its hooks in the profile's order, each as a separate process with the original stdin and arguments. A hook without an action defers to the next. A successful action ends the list; if every hook defers, the lifecycle takes its no-action outcome. Only hooks named in the resolved profile run; see [`CONFIG.md`](CONFIG.md#profiles).

### Hook output

A hook follows the shared [channels](#channels) and [presentation](#presentation). It settles after exit 0. A nonzero exit fails the operation and retains accepted state, with stderr in the diagnostic.

Model text from one lifecycle reaches the model grouped in `<hook name="LIFECYCLE">`, each result inserted verbatim. Bundled hooks wrap theirs in `<context script="NAME">`.

A hook changes the lifecycle's outcome by writing an `action` line to fd 3. The last action from that hook wins and applies only after exit 0. Without an action, the next hook runs.

### Lifecycle reference

| Hook | argv | stdin | Actions | No action |
| --- | --- | --- | --- | --- |
| `session_start` | — | Empty | None | Finish creation |
| `user_prompt_submit` | — | Exact prompt | `block`, `handoff`, `session_update` | Submit the prompt |
| `permission_request` | `NAME ID` | Tool request | `allow`, `deny` | Defer to a capable client, otherwise deny |
| `pre_tool_use` | `NAME ID` | Tool request | `deny` | Execute the tool |
| `post_tool_use` | `NAME ID` | Tool response | None | Continue |
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

A block ends the turn without submitting the prompt. A handoff asks a capable client to run the complete `argv` after a clean turn exit. A session update's `PROFILE` is one complete session profile, as stored in the header; Shellfish atomically replaces it. A `pre_tool_use` deny reason becomes the refused tool result. A `stop` continue requires settled model text, then continues inference with it. `pre_tool_use` and `post_tool_use` cannot rewrite tool input or results. A result is already durable when `post_tool_use` runs, and its context still reaches the model with that result. `permission_request` may only allow or deny a supported sandbox bypass.

## Backend adapters

A backend adapter translates between Shellfish's provider-neutral protocol and one inference provider. It owns request projection, transport, stream parsing, response assembly, and provider-specific validation. The core validates, persists, and recovers complete assistant responses.

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
  "request": {"model": "provider-model"},
  "endpoint": "https://api.example.com/v1/messages"
}
```

`messages` contains provider-neutral conversation records in transcript order. `tools` contains model-facing tool definitions. `request` contains the merged model's common and provider-specific settings, and unrelated fields pass through. `endpoint` is authoritative for the exchange. Bundled adapters read `SHELLFISH_HTTP_TIMEOUT`, `SHELLFISH_HTTP_STALL`, and `SHELLFISH_INSECURE_TLS` from the environment.

Bundled adapters normalize token limits in this order: `max_output_tokens`, `max_completion_tokens`, `max_tokens`. `reasoning_effort` overrides `reasoning.effort`, and `response_schema` replaces the provider-native structured-output setting. The Codex adapter omits output limits because its endpoint rejects them. Bundled adapters always stream and reject a `stream` option.

### Response stream

The adapter writes JSON lines: text and reasoning deltas as the provider streams, then exactly one complete assistant response.

```json
{"type":"_assistant_reasoning_delta","text":"Checking "}
{"type":"_assistant_message_delta","text":"Let me look."}
{"type":"assistant","stop":"tool_calls","content":[...],"usage":{"input_tokens":10,"output_tokens":4}}
```

Deltas arrive in order and concatenate to the response's text and reasoning. An adapter that receives a whole body at once emits it as one delta per block. The response is the record Shellfish will append, in the transcript's own shape: ordered text, reasoning, and tool-call content, a `stop` of `end`, `tool_calls`, or `length`, and optional usage. Only `tool_calls` carries calls, so a response cut short by the output limit drops them. Tool-call fragments, opaque reasoning payloads, and provider correlation stay inside the adapter until they belong to that response.

Nothing may follow the response, and the adapter must then exit 0. Stderr is failure diagnostics, never stream data. A nonzero exit or invalid stream fails the request.

The core validates the response before persisting it or permitting tool execution. If the request is cancelled first, the text and reasoning its deltas streamed are kept as a cancelled response.

### Context-window discovery

An optional executable `context_window` receives the same request and environment before the first provider request when capacity is absent. It returns:

```json
{"context_window":200000}
```

The value must be positive. Failure or any other output means metadata is unavailable and does not fail inference. Discovery must not make a generation request.
