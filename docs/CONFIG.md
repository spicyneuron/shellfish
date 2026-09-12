# Configuration

Shellfish reads JSONC from `$XDG_CONFIG_HOME/shellfish/shellfish.jsonc`, or `~/.config/shellfish/shellfish.jsonc` when `XDG_CONFIG_HOME` is unset. User configuration is merged over the bundled [`share/default/shellfish.jsonc`](../share/default/shellfish.jsonc). Objects merge recursively and arrays replace their defaults.

Run `shellfish config --init` to create the configuration directory from the bundled [`share/template/`](../share/template/). Initialization creates `shellfish.jsonc`, `example.env`, and empty `hooks/`, `backends/`, `tools/`, and `skills/` directories without replacing existing customization assets. Newly created files are mode `0600` and directories are mode `0700`; existing asset permissions are unchanged. Copy `example.env` to `.env` and set the credential for the selected backend. Add `--sandbox-auto` to include detected development-tool paths in the new configuration. Use `shellfish config` to inspect what a new session would use.

## Choose a backend and model

A profile combines a backend, a harness, and provider request settings. The built-in backends need only a model and their documented credential:

```jsonc
{
  "default_profile": "agent",
  "profiles": {
    "agent": {
      "extend": "default",
      "backend": "openrouter",
      "request": {"model": "MODEL"}
    }
  }
}
```

`extend` merges the parent profile into the child using the same object and array rules. Inheriting `default` retains the bundled harness and request defaults.

An optional `context_window` records the model's input capacity for usage display and hooks:

```jsonc
{
  "profiles": {
    "agent": {
      "extend": "default",
      "backend": "openrouter",
      "context_window": 200000,
      "request": {"model": "MODEL"}
    }
  }
}
```

The field has three states:

- **A positive integer** is authoritative and skips discovery.
- **An explicit `null`** disables discovery and threshold-based compaction.
- **Absent** means a backend with an optional `context_window` script makes one best-effort model metadata lookup before the session's first provider request. The bundled Anthropic script uses `max_input_tokens`; the OpenAI-compatible script uses a matching model's `context_length` when the provider supplies it, including OpenRouter; and Codex reads the installed CLI's bundled model catalog. OpenAI's own Models API does not currently supply this field.

An unavailable lookup does not fail the turn; Shellfish freezes `null` into the session and usage remains visible without a capacity fraction. A discovered value is also frozen into the session header. A command-line `--model` override does not remove a configured `context_window`, so use a matching profile when the replacement model has a different limit.

A custom OpenAI-compatible service can reuse the built-in adapter:

```jsonc
{
  "default_profile": "work",
  "backends": {
    "work": {
      "adapter": "openai",
      "endpoint": "https://example.test/v1/chat/completions",
      "environment": ["OPENAI_API_KEY"]
    }
  },
  "profiles": {
    "work": {
      "extend": "default",
      "backend": "work",
      "request": {"model": "MODEL"}
    }
  }
}
```

Put credentials in the environment or in `.env` beside `shellfish.jsonc`. Exported values take precedence.

## Configure component environments

Backend, tool, and hook manifests declare the environment variable names their scripts may receive. A backend configuration can replace its adapter manifest's `environment` array when that adapter supports different inputs. Tool and hook environments come from their component manifests.

Shellfish resolves each selected name first from an exported variable and then from `.env` beside `shellfish.jsonc`. An exported empty value still takes precedence. Missing values remain unset. Names and the resolved `.env` path are frozen in the session runtime, while values remain external and are resolved for each invocation.

Each backend and hook inherits the ordinary process environment except that Shellfish removes every name declared by any component in the frozen runtime, then restores only the names selected by that component. Tools start with a clean environment and receive only their selected values plus Shellfish's fixed tool execution environment. This prevents one configured component from receiving another component's declared settings. For hooks and tools, fixed context is applied after selected values, so the Shellfish value wins a collision.

Environment names must be unique within an array and match `[A-Za-z_][A-Za-z0-9_]*`.

## Customize a harness

Harnesses choose tools, hooks, sandbox policy, and turn limits. They do not have an inheritance field, so a named harness should list the capabilities it needs. The system prompt belongs to the profile, so one harness can serve profiles with different instructions:

```jsonc
{
  "default_profile": "review",
  "harnesses": {
    "review": {
      "tools": ["read_file"],
      "sandbox": true,
      "session_start": ["project_environment", "project_instructions"]
    }
  },
  "profiles": {
    "review": {
      "extend": "default",
      "harness": "review",
      "system": ["review.md"],
      "backend": "openrouter",
      "request": {"model": "MODEL"}
    }
  }
}
```

This example reads its system component from `system/review.md` under the configuration directory. Hook names and behavior are defined in [`HOOKS.md`](HOOKS.md). Tool directories contain an executable `run` and a `manifest.json` or `manifest.jsonc`. Sandboxed tools also contain `fence.jsonc`. Tool processes receive `SHELLFISH_CONFIG_DIR`, the directory containing the resolved config file or its prospective default location. They also receive `SHELLFISH_SESSION`, `SHELLFISH_EXECUTABLE`, and `SHELLFISH_MAX_CAPTURE_BYTES` for the active invocation.

Hook manifests may provide running display labels except on `permission_request`; permission hooks must omit `display` or set it to an empty string.

## Resolve component references

System components, tools, hooks, and backend adapters accept these reference forms:

1. Absolute paths.
2. `~/...` paths relative to `$HOME`.
3. Relative paths under the matching configuration subdirectory, falling back to bundled defaults.

The matching subdirectories are `system/`, `tools/`, `backends/`, and `hooks/<hook>/`. This lets a local component shadow a bundled component with the same name.

## Sandbox grants

The default harness runs its tools with [`fence`](https://github.com/fencesandbox/fence). Each tool has a policy scoped to the filesystem and network access its capability requires. Policies deny access outside those boundaries, including local network access unless explicitly allowed.

Deny patterns take precedence over allows, so `.env` files, `.netrc`, `.npmrc`, and key material stay unreadable and unwritable even inside the project. Credential files such as `~/.git-credentials` are denied by name inside the project and denied by default outside it.

Accessing a path outside a tool's filesystem policy requires an approved sandbox bypass when that tool supports one. A sandbox grant makes the path available inside the sandbox instead, so the model does not need to request a bypass. Grants do not override deny patterns.

Grant paths may be absolute or start with `~/`. Shellfish expands `~/` against `$HOME` before freezing the session runtime. Other environment-variable interpolation is not supported.

```jsonc
{
  "harnesses": {
    "default": {
      "sandbox_read_paths": ["/path/to/reference"],
      "sandbox_write_paths": ["/path/to/output"]
    }
  }
}
```

A read grant allows reading. A write grant allows reading and writing. For a one-off new session, use repeatable `--sandbox-read PATH` and `--sandbox-write PATH` flags. Setting a harness's `sandbox` to `false` runs its tools with full user permissions.

Use `--sandbox-auto` to grant detected development-tool paths. It supports Git configuration, attributes, ignore files, and includes, along with caches and stores from Go, uv, Python and pip, npm, pnpm, Rust, and Cargo. Unavailable tools, failed commands, and paths that do not exist are skipped. Explicit `--sandbox-read` and `--sandbox-write` grants are added to the detected paths.

For chat and `run`, automatic grants are frozen into a new session like other runtime overrides. `shellfish config --sandbox-auto` previews the resolved runtime. `shellfish config --init --sandbox-auto` writes the detected paths into the default harness in the new configuration. Grant paths selectively because a cache grant exposes everything inside it.

## Existing sessions

A session retains the resolved backend, harness, request, sandbox settings, and system component paths stored in its header. Ordinary runtime overrides cannot be applied when opening an existing session. Themes and TUI preview settings come from the current configuration.

Hook-requested session updates merge recursively into the header during the current turn. Arrays, scalars, and `null` replace the existing value, and the result must remain a canonical session runtime. Updates to different fields compose, while updates that replace the same scalar or array are last-writer-wins.

Use the session path to inspect that combination:

```sh
shellfish config --session-from path/to/session.jsonl
```
