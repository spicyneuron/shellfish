# Backends

A backend adapter translates between Shellfish's provider-neutral protocol and one inference provider. The adapter owns request projection, transport, stream parsing, and provider-specific validation. The core owns response assembly, persistence, recovery, hooks, permissions, and tool execution.

Adapters are trusted executables. They run with the user's permissions and outside the tool sandbox. Their manifests select which component-specific environment variables they receive.

## Adapter component

An adapter directory contains an executable `run` and a `manifest.json` or `manifest.jsonc`:

```json
{
  "endpoint": "https://api.example.com/v1/messages",
  "environment": ["EXAMPLE_API_KEY"]
}
```

The manifest supplies the default endpoint and declares environment access. Backend configuration may override both and set transport options. See [`CONFIG.md`](CONFIG.md) for configuration, credential resolution, and component lookup.

An adapter may also provide an executable `context_window` for best-effort model metadata discovery.

## Request contract

Shellfish starts `run` once per provider request. The adapter receives one canonical JSON object on stdin:

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

`messages` contains provider-neutral conversation records in transcript order. `tools` contains tool definitions. `options.request` contains the resolved model and provider request overrides. `transport` is authoritative for the exchange.

The adapter maps these values into the provider's protocol and should reject ambiguous or conflicting provider-native options.

## Response contract

The adapter writes one normalized JSON event per line to stdout:

```json
{"type":"_assistant_message_delta","index":0,"text":"answer"}
{"type":"_assistant_reasoning_delta","index":1,"text":"summary"}
{"type":"_assistant_reasoning_opaque","index":1,"opaque":{}}
{"type":"_assistant_tool_call_delta","index":2,"id":"call_1","name":"shell","input":"{}"}
{"type":"_turn_usage","input_tokens":10,"output_tokens":4,"cached_tokens":2,"reasoning_tokens":1}
{"type":"_assistant_end","stop":"tool_calls"}
```

Indexes are non-negative integers that determine the final order of content blocks. Updates to one index must retain its content type. Text, reasoning text, and tool input are append-only fragments. Opaque reasoning is a complete object associated with a reasoning index and preserves provider data needed by later requests. Repeated opaque values for one index must match.

Normalized events cannot contain extra provider-native fields. Correlation needed only while parsing the current stream may stay adapter-local. Provider data needed by later requests belongs in opaque reasoning.

A tool-call update contains an index and at least one of `id`, `name`, or `input`. The ID and name cannot change after they appear. Input is raw JSON text that must form an object when complete, and call IDs must be unique within the response. Adapters report calls but never execute them.

Usage is optional. It contains non-negative `input_tokens` and `output_tokens`, with optional `cached_tokens` and `reasoning_tokens`. Cached tokens cannot exceed input tokens. The latest usage event becomes authoritative.

Exactly one `_assistant_end` closes the stream, with `stop` set to `end`, `tool_calls`, or `length`. `tool_calls` requires complete calls, `end` cannot include calls, and `length` discards any calls. The end event must be final and followed by a zero adapter exit. Stderr is reserved for failure diagnostics and is not part of the normalized stream.

The core validates and assembles the complete response before persisting it or allowing tool execution.

## Context window lookup

When configured model capacity is absent, Shellfish may run the adapter's `context_window` executable before the first provider request. It receives the same canonical request and selected environment as `run` and returns:

```json
{"context_window":200000}
```

The value is a positive token count. Failure or any other output means metadata is unavailable and does not fail the provider request. The lookup must not make a generation request.

## Failure and cancellation

A nonzero adapter exit or invalid event stream fails the provider request. Cancellation terminates the adapter and its ordinary descendants. Daemonizing is unsupported. Session persistence and partial-response recovery remain the core's responsibility.
