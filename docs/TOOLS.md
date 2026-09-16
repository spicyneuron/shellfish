# Tools

Tools let the model act through executable components selected by a harness. The core assembles and records each call, runs policy and permission hooks, invokes the tool, and commits its result. A tool never writes the session transcript directly.

## Tool component

A tool directory contains an executable `run`, a `manifest.json` or `manifest.jsonc`, and a `fence.jsonc` when the tool opts into sandboxing:

```json
{
  "description": "Read one project file.",
  "input_schema": {
    "type": "object",
    "additionalProperties": false,
    "required": ["path"],
    "properties": {
      "path": {"type": "string", "minLength": 1}
    }
  },
  "render": {
    "initial_user_text": "${name} ${input.path}",
    "user_text": "${name} ${input.path}\n${output.stdout}${output.stderr}",
    "permission_user_text": "${input.path}"
  },
  "sandbox": true,
  "allow_sandbox_bypass": true,
  "environment": ["TOOL_SETTING"]
}
```

`description`, `input_schema`, and `sandbox` are required. The input schema must describe an object. `environment` selects component-specific variables and defaults to empty. `allow_sandbox_bypass` defaults to false and is valid only for a sandboxed tool.

A manifest may override `initial_user_text` and `permission_user_text` before execution and `user_text` and `model_text` for the result. Supplied fields merge over defaults that show the tool name and input on one line, then return stdout and stderr without an exit code. Empty rendered text is omitted. Templates use one-pass `${...}` substitution with `name`, `input`, `input.FIELD`, `output.stdout`, `output.stderr`, and `output.exit_code`. Output variables are available only to result templates. See the manifests under [`share/default/tools/`](../share/default/tools/) for examples.

If a provider requests an undeclared tool, Shellfish uses a plain default template so the call and its rejection remain visible to the user and model.

See [Configuration](CONFIG.md#customize-a-harness) for component lookup and environment value resolution.

## Process contract

Shellfish runs `run` with no arguments from the session working directory. stdin contains the tool input as one JSON object, with sandbox-bypass control fields removed. Tool scripts must validate this input before using it.

Shellfish captures stdout and stderr separately, then renders them into optional user- and model-facing result text; raw capture is not durable. The result repeats the model's exact call input and records its exit code. A nonzero exit is a normal tool result and does not itself fail the turn.

Each turn receives a private temporary directory through `TMPDIR` and `TMPPREFIX`. Its tool calls share that directory, and Shellfish removes it during turn cleanup.

Sandboxed tools start with a clean environment. Tools running without a sandbox inherit Shellfish's local environment. Both receive selected component variables and:

| Variable | Meaning |
| --- | --- |
| `SHELLFISH_CONFIG_DIR` | Directory containing the config file, or its prospective default |
| `SHELLFISH_SESSION` | Absolute path of the active session JSONL |
| `SHELLFISH_EXECUTABLE` | Absolute path of the invoked Shellfish executable |
| `SHELLFISH_MAX_CAPTURE_BYTES` | Combined result and control byte limit |

## Durable state

A tool may write one JSON object to fd 3 containing only state requests:

```json
{"state":[{"name":"tools/example","value":true}]}
```

A state name is at most 128 characters and must match `^[A-Za-z0-9][A-Za-z0-9_.:/-]*$`. The latest value for an exact name is effective, and `null` clears it.

Shellfish appends valid state after normal tool completion and before the tool result, including when the tool exits nonzero. An interrupted tool or orchestration failure commits no requested state. Control bytes count against the capture limit, and remaining result output may be truncated to fit.

A tool that starts a model-authored or otherwise untrusted child command must close fd 3 first so that child cannot forge state.

## Sandboxing and permission

When both the harness and tool enable sandboxing, Shellfish runs the tool under [`fence`](https://github.com/fencesandbox/fence) using the component's `fence.jsonc`. Harness path grants extend that policy, but deny rules still take precedence. A tool with `sandbox: false`, or any tool in a harness with sandboxing disabled, runs with the user's permissions.

When the sandbox blocks an access and the tool then exits non-zero, Shellfish appends a `<sandbox_notice>` to the result's model text. The notice is advisory: the block is not necessarily what failed the tool.

For a sandboxed tool with `allow_sandbox_bypass: true`, Shellfish adds `request_sandbox_bypass` and `sandbox_bypass_reason` to the model-facing input schema. These control fields are removed before the tool runs. A request proceeds unsandboxed only after a hook or interactive client approves it. Otherwise Shellfish records a denied result without invoking the tool.

## Cancellation

Each tool runs in an isolated process group. Completion and cancellation terminate ordinary descendants left in that group. Tools must finish their own subprocesses, and daemonizing is unsupported.
