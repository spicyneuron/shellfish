# Backends

A backend adapter translates between Shellfish's provider-neutral request and one provider API. It owns provider request projection, transport, stream parsing, correlation, and semantic translation. Exec owns response assembly, session persistence, recovery, hooks, permissions, and tool execution.

Backend adapters are trusted executables. They run with the user's permissions and are not placed inside the tool sandbox.

## Adapter layout

An adapter directory contains an executable `run` and a `backend.json` manifest:

```json
{
  "endpoint": "https://api.example.com/v1/messages",
  "api_key_env": "EXAMPLE_API_KEY"
}
```

`endpoint` supplies the default provider endpoint. `api_key_env` names the environment variable Shellfish resolves from exported variables or the adjacent `.env`; an empty name means the backend does not use this credential mechanism. Backend configuration may override the endpoint, credential name, and transport settings described in [`CONFIG.md`](CONFIG.md).

Component lookup rules for bundled, user-defined, relative, and absolute adapter references are also documented in [`CONFIG.md`](CONFIG.md#resolve-component-references).

## Process contract

Exec starts `run` once per provider request. The adapter receives one canonical JSON request on stdin and writes one normalized JSON object per line to stdout. Stderr is not part of the normalized stream. If the adapter fails, exec sanitizes and truncates its stderr for `_exec_error`; successful stderr is discarded.

The turn exposes the resolved credential only as `SHELLFISH_API_KEY` for the adapter process. `SHELLFISH_API_KEY_SOURCE` identifies where it was resolved. Adapters should copy credentials only as long as needed to prepare authentication and then unset them. An adapter with an empty `api_key_env` is responsible for any alternative authentication; the bundled Codex adapter reads an existing Codex CLI login.

The input has this top-level shape:

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

`messages` contains provider-neutral user, assistant, and tool-result messages projected from the durable session. Assistant content may contain text, reasoning with provider-specific `opaque` data, and completed tool calls. `tools` contains canonical tool definitions. `options.request` contains the resolved model and request overrides; the adapter maps supported options to provider fields and should reject conflicting provider-native fields rather than silently producing an ambiguous request. `transport` is authoritative for the exchange.

### Context window lookup

An adapter directory may contain an executable `context_window` alongside `run`. Shellfish freezes its resolved path with the backend runtime. Before the first provider request, exec invokes it only when the profile has no `context_window` field. The script receives the same canonical request and scoped credential as `run`. A successful lookup writes exactly one object and exits zero:

```json
{"context_window":200000}
```

`context_window` is a positive integer token count. A nonzero exit or any other output means metadata is unavailable; stderr is discarded and the provider request still proceeds. The turn freezes a successful value into the profile and freezes `null` after an unavailable result, so that session does not retry.

Model lookup is separate from the normalized response stream. The script must not make a generation request.

## Normalized response stream

Every stdout line must be exactly one of these event shapes:

```json
{"type":"_assistant_delta","index":0,"text":"answer"}
{"type":"_assistant_reasoning_delta","index":1,"text":"summary"}
{"type":"_assistant_reasoning_opaque","index":1,"opaque":{}}
{"type":"_assistant_tool_call_delta","index":2,"id":"call_1"}
{"type":"_assistant_tool_call_delta","index":2,"name":"shell","input":"{\"command\":\""}
{"type":"_assistant_tool_call_delta","index":2,"input":"echo ok\"}"}
{"type":"_turn_usage","input_tokens":10,"output_tokens":4,"cached_tokens":2,"reasoning_tokens":1}
{"type":"_assistant_response_end","stop":"tool_calls"}
```

Content indexes are bounded non-negative integers. They identify blocks in the canonical assistant content and determine its final order. Updates with the same index must describe the same content type. Text, reasoning text, and tool input are append-only fragments; a non-streaming adapter may emit one complete fragment per block.

Opaque reasoning is a complete provider object associated with a reasoning index, not display text. Emit it when the provider has supplied the authoritative continuation data that must survive request projection. Repeated opaque values for one index must agree.

A tool-call update must contain at least one of `id`, `name`, or `input`. The ID and name are immutable once supplied. `input` contains raw JSON text fragments, not parsed JSON. The turn concatenates the fragments and requires the completed input to be an object. Tool-call IDs must be unique within the response.

Usage is optional. The latest valid `_turn_usage` before response end becomes the assistant message's canonical usage. Token counts are non-negative integers; cached tokens cannot exceed input tokens.

Exactly one `_assistant_response_end` must be the final event. Its stop value is `end`, `tool_calls`, or `length`. The response succeeds only when the adapter then exits zero. EOF is never implicit success, and nothing may follow response end.

## Assembly and recovery

Exec validates the normalized stream and assembles the canonical assistant message. It rejects conflicting block metadata, invalid tool input, duplicate call IDs, and disagreement between content and the stop reason. The message is appended before hooks, permissions, or tools can act, so an adapter must never execute tool calls itself.

If an adapter fails or is cancelled without successfully completing the response, turn cleanup best-effort preserves accepted visible text and reasoning as an assistant message with `stop: "length"`. Opaque data attached to recovered reasoning is retained for future provider requests. Usage and incomplete tool calls are discarded, even when the received tool input is valid JSON. A response with no visible content uses ordinary turn recovery instead.

This recovery is not a durability guarantee across `SIGKILL`, process crashes, or machine loss. Provider-specific validation should still fail promptly and write a concise diagnostic to stderr.

## Provider-specific state

Adapters may retain response-local state needed to correlate provider events, validate provider block lifecycles, convert cumulative fields into deltas, or map provider indexes into canonical content order. They should not assemble or emit canonical assistant messages.

Explicit provider block boundaries need not be reproduced in the normalized stream. The first update creates a canonical block and response end completes the response. Provider APIs without streaming use the same protocol.
