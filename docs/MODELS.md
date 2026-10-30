# Models

A model configures where inference requests go and what they carry. It is selected separately from the profile, so the same agent can use different models without changing its tools or workflow.

See [`CONFIG.md`](CONFIG.md) for setup, directory selection, and reference lookup, and [Components](COMPONENTS.md#providers) for writing providers. The [`model.schema.json`](../share/model.schema.json) is the exact field reference.

## Selection

`-m REF|JSON` or `--model REF|JSON` selects a model file or an inline object. When the option is absent, Shellfish uses `models/default.jsonc`.

```jsonc
// models/work.jsonc
{
  "provider": "anthropic",
  "request": {"model": "MODEL", "max_tokens": 16384}
}
```

```sh
shellfish -m work
shellfish -m '{"provider": "openrouter", "request": {"model": "MODEL"}}'
```

| Field | Meaning |
| --- | --- |
| `provider` | Provider reference |
| `config` | Optional provider settings, separate from API request parameters |
| `endpoint` | Overrides the provider's default endpoint |
| `context_window` | Positive capacity override. `null` disables discovery, and absent permits provider discovery |
| `request` | API request parameters, which must include `model` after merging |

`shellfish init` copies a starter model using OpenRouter, up to 16,384 output tokens, and medium reasoning effort. Replace its `MODEL` placeholder and supply credentials before starting a session.

### Merging

`-m` repeats, and its items merge left to right. Objects merge recursively and anything else is replaced. A file that names its provider and model stands alone, and small files can adjust it:

```jsonc
// models/local.jsonc
{"provider": "openai_chat", "endpoint": "http://127.0.0.1:8080/v1/chat/completions",
 "request": {"model": "local-model"}}

// models/high.jsonc
{"request": {"reasoning": {"effort": "high"}}}
```

```sh
shellfish -m local -m high
shellfish -m work -m '{"request": {"model": "ANOTHER_MODEL"}}'
```

Editing a model file does not change an existing session's model configuration. A forked subagent keeps its parent's model.

## Providers and credentials

A provider connects Shellfish to an inference API. Bundled conversation providers are:

| Provider | Credential |
| --- | --- |
| `anthropic` | `ANTHROPIC_API_KEY` |
| `codex` | Existing Codex CLI login |
| `openai_chat` | `OPENAI_API_KEY` |
| `openai_responses` | `OPENAI_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |

Keep keys in the selected Shellfish directory's `.env` or exported variables, not in model files. See [Environment](CONFIG.md#environment) for precedence and [Component trust](COMPONENTS.md#environment-and-trust) for credential access rules.

The `openai_chat` provider also supports OpenAI-compatible services by setting `endpoint`, as in the local model above.

### Request settings

The `request` object holds API parameters. Bundled conversation providers normalize output limits in this order: `max_output_tokens`, `max_completion_tokens`, `max_tokens`. `reasoning_effort` overrides `reasoning.effort`, and `response_schema` replaces the provider-native structured-output setting. Codex omits output limits because its endpoint rejects them. Bundled conversation providers always stream and reject a `stream` option.

The model's `config` object controls the exchange rather than API parameters. Bundled HTTP providers use these defaults:

| Setting | Default | Meaning |
| --- | --- | --- |
| `http_timeout` | `3600` | Positive integer seconds per provider request |
| `http_stall` | `300` | Positive integer seconds without response bytes |
| `insecure_tls` | `false` | Disables TLS certificate verification when true |

For example, `"config": {"http_timeout": 120, "http_stall": 30}` sets shorter limits. Leave TLS verification enabled. The Codex provider always requires it.

### Context window

Set `context_window` when you know the model's capacity. Otherwise Shellfish lets the provider discover it without making a generation request. Unavailable metadata does not prevent inference. Set the field to `null` to disable discovery.

## Standalone requests

Hooks and scripts can call `shellfish request` with a session transcript on stdin to obtain one assistant response without running tools, hooks, or changing the session:

```sh
shellfish request < session.jsonl
shellfish request -m work -m high < session.jsonl
```

Without `-m`, the request uses the transcript's frozen model. Explicit model items merge with each other and replace the complete model for that request only, rather than merging into the transcript's model. References follow the same lookup rules as session creation.

## Decisions

A decision asks typed questions about one input and returns a calibrated answer to each, without a conversation or tool calls. Hooks and scripts use `shellfish decide -m REF|JSON` with a decision on stdin. A model is required, and its provider must support decisions.

| Provider | Credential | Use |
| --- | --- | --- |
| `openai_decisions` | `OPENAI_API_KEY` | OpenAI Decisions API |
| `systemone` | `TYPESAFE_API_KEY` | TypeSafe System One API |
| `openai_decisions_omlx` | Optional `OMLX_API_KEY` | oMLX endpoint using the OpenAI format |
| `systemone_omlx` | Optional `OMLX_API_KEY` | oMLX endpoint using the System One format, including video |

The oMLX providers require an endpoint:

```jsonc
// models/d3.jsonc
{"provider": "systemone_omlx", "endpoint": "http://127.0.0.1:8000/v1/systemone",
 "request": {"model": "d3-flash"}}
```

```sh
shellfish decide -m d3 <<'JSON'
{
  "system": "Judge only the supplied input.",
  "input": [{"type": "text", "text": "The build finished with exit code 0."}],
  "questions": {
    "passed": {"type": "predicate", "instructions": "Did the build succeed?"}
  }
}
JSON
```

Inputs can be `text`, `json` with a `data` value, or `image` and `video` with a data URI or HTTP(S) `url`. Media support depends on the provider.

Questions are keyed by name and answered independently:

| Type | Question settings | Answer |
| --- | --- | --- |
| `predicate` | `instructions`, optional `criteria` describing `true` and `false` | `probability` that the statement is true |
| `choice` | `instructions`, `choices` mapping 2 to 255 names to descriptions or `null` | Selected `choice`, `confidence`, and probabilities by name |
| `score` | `instructions`, `levels` listing 2 to 10 ordered labels | `score`, `confidence`, and probabilities in level order |

The result contains `model`, an `answers` object keyed like the questions, and optional `usage`. Each answer includes its `type`. Probabilities and confidences range from 0 to 1. A score is the probability-weighted level index, from 0 for the first level to the last level's index. A declined question receives `{"type":"refusal"}` instead of an estimate. An unsupported input or invalid result fails the request rather than silently dropping information.
