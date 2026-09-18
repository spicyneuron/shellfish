# Configuration

Shellfish reads JSONC from `$XDG_CONFIG_HOME/shellfish/shellfish.jsonc`, or `~/.config/shellfish/shellfish.jsonc` when `XDG_CONFIG_HOME` is unset. User configuration is merged over the bundled [`share/default/shellfish.jsonc`](../share/default/shellfish.jsonc). Objects merge recursively and arrays replace their defaults.

To start from a working example, copy [`share/template/`](../share/template/) into that directory and edit it.

## Profiles

A profile combines a backend, harness, system prompt, and provider request settings. A common profile extends the bundled default and selects a backend and model:

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

`extend` merges a parent profile into the child. Extending `default` retains the bundled profile defaults while allowing the child to replace its backend, harness, system prompt, or model settings.

The optional `context_window` setting supplies the model's input capacity for usage display and hooks. A positive integer is authoritative, `null` disables discovery, and an absent value allows the backend to attempt best-effort discovery. Keep it aligned with the selected model.

Put credentials in the environment or in `.env` beside `shellfish.jsonc`. Exported values take precedence.

To use an OpenAI-compatible service, configure a named backend that reuses the bundled adapter:

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

See [`BACKENDS.md`](BACKENDS.md) for the adapter contract.

## Configure component environments

Backend, tool, and hook manifests declare component-specific environment variables. Values are resolved from exported variables and then `.env`; missing values remain unset. Names and the `.env` location are frozen in the session, while values remain external and are resolved for each invocation.

Hooks and backend adapters are trusted programs. They inherit the ordinary process environment minus every name any component declares, and their manifests select additional values to load from `.env`, so no component inherits another's credentials. Sandboxed model-facing tools start with a clean environment; unsandboxed tools inherit the ordinary process environment the same way. Both receive their selected values and fixed Shellfish tool context.

## Customize a harness

Harnesses choose tools, hooks, sandbox policy, and turn limits. They do not inherit, so each harness lists the capabilities it needs. System prompts belong to profiles, allowing one harness to serve different instruction sets. See [`HARNESS.md`](HARNESS.md) and [`HOOKS.md`](HOOKS.md) for their roles.

For example, a focused review profile can use a read-only tool set and its own instructions:

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

System components, tools, hooks, and backend adapters may be referenced by absolute path, by a path under `~/`, or by name. Named components resolve under the matching configuration subdirectory and then fall back to bundled defaults, so user components can shadow bundled components.

## Sandbox grants

The default harness runs tools with [`fence`](https://github.com/fencesandbox/fence). Each tool has a policy limiting its filesystem and network access. Deny rules protect common credential files and always take precedence over grants.

Harness grants extend filesystem access without bypassing the sandbox:

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

A read grant allows reading; a write grant allows reading and writing. Use `--sandbox-read` and `--sandbox-write` for one-off grants, or `--sandbox-auto` to include detected development-tool paths. Setting `sandbox` to `false` runs tools with full user permissions. Grants become part of the new session's frozen runtime.

## Existing sessions

A session retains its resolved runtime rather than reinterpreting current configuration, so opening one rejects ordinary runtime overrides. Themes and global TUI preview settings remain current client configuration.

See [`SESSIONS.md`](SESSIONS.md) for the runtime boundary and derivation semantics.
