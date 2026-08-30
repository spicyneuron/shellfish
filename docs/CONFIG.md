# Configuration

Shellfish reads JSONC from `$XDG_CONFIG_HOME/shellfish/shellfish.jsonc`, or `~/.config/shellfish/shellfish.jsonc` when `XDG_CONFIG_HOME` is unset. User configuration is merged over the bundled [`default/shellfish.jsonc`](../default/shellfish.jsonc). Objects merge recursively and arrays replace their defaults.

Run `shellfish config --init` to create the configuration directory and copy [`shellfish.template.jsonc`](../shellfish.template.jsonc). Add `--sandbox-auto` to include detected development-tool paths in the new configuration. Use `shellfish config` to inspect what a new session would use.

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

Put credentials in the environment or in `.env` beside `shellfish.jsonc`. Exported values take precedence.

## Customize a harness

Harnesses choose prompt files, tools, hooks, sandbox policy, and turn limits. They do not have an inheritance field, so a named harness should list the capabilities it needs:

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

This example reads its prompt from `prompts/review.md` under the configuration directory. Hook event names and behavior are defined in [`HOOKS.md`](HOOKS.md). Tool directories contain an executable `run` and a `tool.json` manifest. Sandboxed tools also contain `fence.jsonc`.

## Resolve component references

Prompt files, tools, hooks, and backend adapters accept these reference forms:

1. Absolute paths.
2. `~/...` paths relative to `$HOME`.
3. Paths containing `/`, relative to the configuration directory.
4. Bare names under the matching configuration subdirectory, falling back to bundled defaults.

The matching subdirectories are `prompts/`, `tools/`, `backends/`, and `hooks/<event>/`. This lets a local component shadow a bundled component with the same name.

## Sandbox grants

The default harness runs its tools with [`fence`](https://github.com/fencesandbox/fence). Each bundled tool sees only the project directory, and network access is blocked entirely, including local ports. `shell`, `edit_file`, and `write_file` may also write inside the project, while `read_file` is read-only.

Deny patterns take precedence over allows, so `.env` files, `.netrc`, `.npmrc`, and key material stay unreadable and unwritable even inside the project. Credential files such as `~/.git-credentials` are denied by name inside the project and denied by default outside it.

Accessing any other path outside the project requires an approved sandbox bypass. A sandbox grant makes the path available inside the sandbox instead, so the model does not need to request a bypass. Grants do not override deny patterns.

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

For chat and `exec`, automatic grants are frozen into a new session like other runtime overrides. `shellfish config --sandbox-auto` previews the resolved runtime. `shellfish config --init --sandbox-auto` writes the detected paths into the default harness in the new configuration. Grant paths selectively because a cache grant exposes everything inside it.

## Existing sessions

A session retains the resolved backend, harness, request, and sandbox settings with which it was created. Runtime overrides cannot be applied when opening an existing session. Themes and TUI preview settings come from the current configuration.

Use the session path to inspect that combination:

```sh
shellfish config --session path/to/session.jsonl
```
