# Components

Components are executable directories that extend Shellfish. Tools let the model act, commands handle user actions, hooks supply context and workflow policy, and providers connect inference APIs.

See [Configuration](CONFIG.md) for setup, reference lookup, and runtime settings, [Profiles](PROFILE.md) for agent composition, and [Models](MODELS.md) for inference configuration and standalone requests. Use the [bundled tools](../share/tools/), [commands](../share/commands/), [hooks](../share/hooks/), and [providers](../share/providers/) as starting points.

## Selection and execution

Install custom components in the selected Shellfish directory:

```text
tools/TOOL/
commands/COMMAND/
hooks/HOOK/
providers/PROVIDER/
```

Tools, commands, and hooks require an executable `run`. Providers supply `run` for conversations, `decide` for decisions, or both. An optional `manifest.json` or `manifest.jsonc` describes the component, with an absent manifest treated as `{}`. Each role requires its own metadata, such as a tool's description and input schema or a hook's lifecycle.

Scripts run from the session working directory. Shellfish isolates their process groups and cleans up ordinary descendants on completion or cancellation. Components must finish their own subprocesses, and daemonizing is unsupported.

Missing or invalid active components fail session creation. Manifests are read on each invocation, so an invalid edit can fail a later run. Only selected components are active. Profiles select tools, commands, and hooks. Models select providers.

## Environment and trust

Credentials follow the [environment rules](CONFIG.md#environment), including exported-variable precedence over `.env`.

Commands, hooks, and providers are trusted programs running with user permissions. They inherit the process environment and receive every `.env` value. Tools receive only the `.env` names their manifest's `environment` list declares. Unsandboxed tools also inherit the process environment. Sandboxed tools start clean apart from declared and Shellfish-provided values.

A key kept only in `.env` is invisible to tools that do not declare it. Choosing a custom hook, command, or provider gives that program access to your credentials.

Tools and hooks receive the frozen profile's `config` as `SHELLFISH_CONFIG`, including when sandboxed.

Tools and hooks receive `SHELLFISH_SESSION`, `SHELLFISH_EXECUTABLE`, `SHELLFISH_DIR`, and `SHELLFISH_SHARE_DIR` alongside their configuration. Hooks also receive the model and turn context. Use public `shellfish` commands to compose workflows rather than modifying transcript files directly.

## Channels

Tools, commands, and hooks use these channels. Providers use their own [response protocol](#providers).

| Channel | Audience | Contents |
| --- | --- | --- |
| stdout | Model | Context or tool result text |
| stderr | User | Text shown through the `user_text` template |
| fd 3 | Shellfish | Newline-delimited JSON control lines |

Nothing on stdout means no model text. Tools should report errors there so the model sees them. A manifest's `max_capture_bytes` overrides the shared capture limit, with a minimum of `64` bytes. Oversized stdout and stderr retain their tails behind an `[output truncated]` marker.

Tools and hooks can request durable named state with control lines such as `{"state_update":[{"name":"example/status","value":{"ready":true}}]}`. The latest exact name wins, and `null` clears it. Accepted state updates survive later component failure. Hooks also use fd 3 for lifecycle actions. Close fd 3 before starting an untrusted child so it cannot send control lines.

## Presentation

The optional `user_text` manifest field controls display for tools, commands, and hooks. Templates can use `${input}`, `${input.FIELD}` for declared tool properties, `${output.stdout}`, and `${output.stderr}`. Strings insert literally, other values insert as JSON, and missing values insert empty. Without a nonempty rendered template, the component shows nothing.

The first line is a header, optionally starting with a bold label such as `**Read** ${input.path}`. Headers take no trailing colon. `user_preview_lines`, a line count or `"full"`, overrides the client's preview limit.

Templates render while the component runs with empty output, then again when it settles. Only settled text is stored, so replay does not depend on current manifests. Refused, skipped, or interrupted calls receive a reason through `${output.stderr}`.

## Tools

A tool manifest describes its model-facing interface and execution policy:

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
  "user_text": "**Read** ${input.path}\n${output.stdout}"
}
```

`description`, an object `input_schema`, and the boolean `sandbox` are required. `allow_sandbox_bypass` defaults to `false` and is valid only for sandboxed tools. `environment` lists the variable names the tool needs. Sandboxed tools receive clean environments plus declared and Shellfish-provided values, and access to platform temporary storage. Tools own their temporary-file cleanup. See [Sandbox](PROFILE.md#sandbox) for session grants and bypass approval.

Shellfish calls `run` without arguments, passing one input object on stdin with bypass fields removed. The tool validates input before using it. A nonzero exit is a normal tool result, not a failed turn. Tools cannot take lifecycle actions.

Tools can return images through `content` control lines, such as `{"content":[{"type":"image","url":"data:image/png;base64,..."}]}`. Parts can be text or base64 PNG, JPEG, GIF, or WebP images. Content follows stdout and is subject to `SHELLFISH_MAX_CONTENT_BYTES` rather than the capture limit.

## Hooks

A hook manifest declares its lifecycle with `on`, such as `{"on":"stop"}`. An optional `match.pattern` jq regular expression filters invocations. A nonmatching hook is skipped. Without a filter, it runs for every invocation at that lifecycle.

| Lifecycle | Purpose | Arguments | stdin | Available actions |
| --- | --- | --- | --- | --- |
| `session_start` | Add context once when creating a session | None | Empty | None |
| `user_prompt_submit` | Add context or handle a prompt before submission | None | Exact prompt | `deny`, `handoff`, `session_update` |
| `pre_tool_use` | Gate a tool call | `NAME ID` | Tool request JSON | `deny` |
| `permission_request` | Review a supported sandbox bypass | `NAME ID` | Tool request JSON | `allow`, `deny` |
| `post_tool_use` | Add context after a durable tool result | `NAME ID` | Tool response JSON | None |
| `stop` | Check whether a turn may finish | `REQUEST_COUNT` | Final assistant text | `deny` |

`NAME` and `ID` are the tool name and call ID. A tool request contains `turn_id`, `tool_name`, `tool_use_id`, and `tool_input`. A tool response adds `tool_response` with `stdout`, `stderr`, and `exit_code`. `REQUEST_COUNT` is the number of provider requests made in the turn.

Hooks run in profile order. Without an action, the next hook runs. A successful action ends the list. Hook output settles on exit 0, and a nonzero exit fails the operation. Context reaches the model grouped by lifecycle and script name.

Hook actions are JSON lines on fd 3, such as `{"action":"deny","reason":"Run the tests first"}`. The last action from a hook applies after exit 0. `deny` prevents the lifecycle's default step. At submission it withholds the prompt, at a tool gate it refuses the call, and at `stop` it continues inference after settled model text.

`allow` approves only a supported bypass. `handoff` supplies an `argv` array for a capable client to run after the turn exits cleanly. `session_update` supplies a complete session `profile` to replace atomically. Tool hooks cannot rewrite inputs or results. See the bundled hooks for input and action examples.

## Commands

A command handles a single-line `/NAME` prompt instead of submitting it, before submission hooks run. Its manifest requires a user-facing `description`. Optional `arguments` supplies a usage hint and enables `/NAME ARGUMENTS`. Without it, only the exact `/NAME` matches. Optional `aliases` supplies alternate names. Names and aliases must be unique within the profile.

```json
{"description": "Copy a conversation section", "arguments": "[N]", "aliases": ["c"],
 "user_text": "${output.stderr}"}
```

Shellfish calls `run` without arguments and passes argument text, without leading whitespace, on stdin. Commands use hook-style channels, presentation, and actions. They may request `handoff` or `session_update`. Otherwise the prompt is withheld. A nonzero exit fails the turn.

Commands also receive `SHELLFISH_COMMANDS`, a JSON array of the profile's command names, descriptions, arguments, and aliases, so a help command can list what is available.

## Providers

Put a provider directory under `providers/` and select it through the model's `provider` field. It supplies an executable `run` for conversations, `decide` for decisions, or both. An optional `manifest.json` or `manifest.jsonc` supplies a default `endpoint`, which a model can override.

Shellfish invokes the provider once per request with JSON on stdin. The provider translates the request to its API and returns normalized output, keeping API-specific parsing and validation inside the provider. Conversation providers may stream text and reasoning deltas, then return one complete assistant response. Decision providers return one result object. Diagnostics go to stderr, and success requires exit 0.

An optional `context_window` executable discovers capacity without generating a response. Failed discovery leaves capacity unknown rather than failing inference.

Use the [bundled providers](../share/providers/) as starting points and the [request definitions](../lib/provider.jq) for the normalized input and output shapes.
