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
  "sandbox": true,
  "allow_sandbox_bypass": true,
  "environment": ["TOOL_SETTING"]
}
```

`description`, `input_schema`, and `sandbox` are required. The input schema must describe an object. `environment` selects component-specific variables and defaults to empty. `allow_sandbox_bypass` defaults to false and is valid only for a sandboxed tool.

A manifest may include `display` settings for interactive clients. Its summary, call, and permission previews can interpolate input fields or `$input_json`. Its result preview can use `$result_preview`, `$result_full`, and `$exit_code`. See the manifests under [`share/default/tools/`](../share/default/tools/) for examples.

See [Configuration](CONFIG.md#customize-a-harness) for component lookup and environment value resolution.

## Process contract

Shellfish runs `run` with no arguments from the session working directory. stdin contains the complete tool input as one JSON object. Tool scripts must validate this input before using it.

Combined stdout and stderr become the tool result content. The process exit status becomes the result exit code. A nonzero exit is a normal tool result and does not itself fail the turn.

Each turn receives a private temporary directory through `TMPDIR` and `TMPPREFIX`. Its tool calls share that directory, and Shellfish removes it during turn cleanup.

Tools start with a clean environment containing basic process values, selected component variables, and:

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

For a sandboxed tool with `allow_sandbox_bypass: true`, Shellfish adds `request_sandbox_bypass` and `sandbox_bypass_reason` to the model-facing input schema. These control fields are removed before the tool runs. A request proceeds unsandboxed only after a hook or interactive client approves it. Otherwise Shellfish records a denied result without invoking the tool.

## Cancellation

Each tool runs in an isolated process group. Completion and cancellation terminate ordinary descendants left in that group. Tools must finish their own subprocesses, and daemonizing is unsupported.
