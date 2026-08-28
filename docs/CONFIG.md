# Configuration

Shellfish reads JSONC from `$XDG_CONFIG_HOME/shellfish/config.jsonc`, or `~/.config/shellfish/config.jsonc` when `XDG_CONFIG_HOME` is unset. User configuration is merged over the bundled [`default/config.jsonc`](../default/config.jsonc). Objects merge recursively and arrays replace their defaults.

Use [`config.template.jsonc`](../config.template.jsonc) as a starting point, and `shellfish config` to inspect what a new session would use.

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

A custom OpenAI-compatible service can reuse the built-in adapter:

```jsonc
{
  "default_profile": "work",
  "backends": {
    "work": {
      "adapter": "openai",
      "endpoint": "https://example.test/v1/chat/completions",
      "api_key_env": "WORK_API_KEY"
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

Put credentials in the environment or in `.env` beside `config.jsonc`. Exported values take precedence.

## Customize a harness

Harnesses choose system files, tools, hooks, sandbox policy, and turn limits. They do not have an inheritance field, so a named harness should list the capabilities it needs:

```jsonc
{
  "default_profile": "review",
  "harnesses": {
    "review": {
      "system": ["review.md"],
      "tools": ["read_file"],
      "sandbox": true,
      "session_start": ["add_environment", "add_project_instructions"]
    }
  },
  "profiles": {
    "review": {
      "extend": "default",
      "harness": "review",
      "backend": "openrouter",
      "request": {"model": "MODEL"}
    }
  }
}
```

This example reads its prompt from `system/review.md` under the configuration directory. Hook event names and behavior are defined in [`HOOKS.md`](HOOKS.md). Tool directories contain an executable `run` and a `tool.json` manifest; sandboxed tools also contain `fence.jsonc`.

## Resolve component references

System files, tools, hooks, and backend adapters accept these reference forms:

1. Absolute paths.
2. `~/...` paths relative to `$HOME`.
3. Paths containing `/`, relative to the configuration directory.
4. Bare names under the matching configuration subdirectory, falling back to bundled defaults.

The matching subdirectories are `system/`, `tools/`, `backends/`, and `hooks/<event>/`. This lets a local component shadow a bundled component with the same name.

## Sandbox grants

The default harness runs its tools with `fence`. Add absolute paths or `~/...` paths outside the project with harness settings. Shellfish expands `~/` against `$HOME` before freezing the session runtime; other environment-variable interpolation is not supported.

New sessions automatically grant read-only access to `~/.gitconfig` and the standard `config`, `ignore`, and `attributes` files under `${XDG_CONFIG_HOME:-~/.config}/git` when they exist. Git configuration can include arbitrary additional files; grant custom include locations explicitly. Fence continues to deny credential files such as `~/.git-credentials`.

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

For a one-off new session, use repeatable `--sandbox-read PATH` and `--sandbox-write PATH` flags. Setting a harness's `sandbox` to `false` runs its tools with full user permissions.

## Existing sessions

A session retains the resolved backend, harness, request, and sandbox settings with which it was created. Runtime overrides cannot be applied when opening an existing session. Themes and TUI preview settings come from the current configuration.

Use the session path to inspect that combination:

```sh
shellfish config --session path/to/session.jsonl
```
