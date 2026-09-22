# Configuration

Shellfish reads JSONC from `$XDG_CONFIG_HOME/shellfish/shellfish.jsonc` (or `~/.config/shellfish/shellfish.jsonc` when `XDG_CONFIG_HOME` is unset). User configuration is merged over the bundled [`share/default/shellfish.jsonc`](../share/default/shellfish.jsonc). Objects merge recursively and arrays replace their defaults.

Copy [`share/template/`](../share/template/) into that directory for a working starting point. The bundled [`shellfish.schema.json`](../share/shellfish.schema.json) is the exact field reference.

## Composition

```text
backend ─┐
harness ─┼─▶ profile ─▶ command-line overrides ─▶ frozen session runtime
system  ─┤
request ─┘
```

- A **backend** selects an adapter and endpoint and declares environment access.
- A **harness** combines tools, ordered lifecycle hooks, sandbox policy, and turn limits.
- A **profile** composes one backend and one harness with system-prompt components and provider request settings.
- A **theme** and global preview limits remain current presentation settings; they are not frozen in sessions.

Profiles may inherit. Backends and harnesses do not have their own inheritance mechanism.

```jsonc
{
  "default_profile": "work",
  "profiles": {
    "work": {
      "extend": "default",
      "backend": "openrouter",
      "request": {"model": "MODEL"}
    }
  }
}
```

`extend` recursively merges the parent profile into the child; child arrays replace parent arrays. Extending `default` retains the bundled harness, system prompt, and request defaults. A resolved new session must have a backend and valid model.

| Profile field | Meaning |
| --- | --- |
| `extend` | Parent profile name |
| `backend` | Name under `backends` |
| `harness` | Name under `harnesses` |
| `system` | Ordered system-component references |
| `request` | Provider request object; `model` is required after resolution |
| `context_window` | Positive capacity override; `null` disables discovery; absent permits adapter discovery |

## Backends

| Field | Default / meaning |
| --- | --- |
| `adapter` | Backend name; selects an adapter component |
| `endpoint` | Adapter manifest endpoint |
| `environment` | Adapter manifest declarations |
| `insecure_tls` | `false` |
| `http_timeout` | `3600` seconds |
| `http_stall` | `300` seconds without response bytes |

An OpenAI-compatible service can reuse the bundled adapter:

```jsonc
{
  "backends": {
    "local": {
      "adapter": "openai",
      "endpoint": "http://127.0.0.1:8080/v1/chat/completions",
      "environment": []
    }
  },
  "profiles": {
    "local": {
      "extend": "default",
      "backend": "local",
      "request": {"model": "MODEL"}
    }
  }
}
```

Bundled adapters: `anthropic`, `codex`, `openai`, `openai-responses`, and `openrouter`. See [`HARNESS.md`](HARNESS.md#backend-adapters) for the adapter protocol.

## Harnesses

Harnesses have no `extend` field. A custom harness lists the capabilities it needs; omitted hook lists and tool lists are empty, while omitted sandbox and limit fields use the defaults below.

| Field | Default / meaning |
| --- | --- |
| `tools` | `[]`; unique tool references exposed to the model |
| `session_start` | `[]`; creation context hooks |
| `user_prompt_submit` | `[]`; prompt gates and interactive commands |
| `permission_request` | `[]`; sandbox-bypass decisions |
| `pre_tool_use` | `[]`; tool policy gates |
| `post_tool_use` | `[]`; post-execution observers |
| `stop` | `[]`; completion gates |
| `sandbox` | `true` |
| `sandbox_read_paths` | `[]`; extra read grants |
| `sandbox_write_paths` | `[]`; extra read-write grants |
| `max_requests_per_turn` | `100` |
| `max_tool_calls_per_request` | `25` |
| `max_capture_bytes` | `32768`; per component execution, minimum `64` |

System prompts belong to profiles, so one harness can serve different roles:

```jsonc
{
  "harnesses": {
    "review": {
      "tools": ["read_file"],
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

## Components and environment

System components, tools, hooks, and adapters may be referenced by absolute path, by a path under `~/`, or by name. Named references resolve under the matching configuration subdirectory, then fall back to [`share/default/`](../share/default/); user components can shadow bundled ones.

| Kind | User directory | Bundled directory |
| --- | --- | --- |
| System | `system/` | `share/default/system/` |
| Tool | `tools/` | `share/default/tools/` |
| Hook | `hooks/HOOK/` | `share/default/hooks/HOOK/` |
| Adapter | `backends/` | `share/default/backends/` |

Component manifests declare environment variable names. Values resolve from exported variables first, then `.env` beside `shellfish.jsonc`; missing values remain unset. The names and `.env` path are frozen, but values remain external and are read for each invocation.

Hooks and adapters inherit the ordinary process environment after every component-declared name is removed, then receive their own selected values. Unsandboxed tools inherit the same filtered environment; sandboxed tools start clean. See [`HARNESS.md`](HARNESS.md#shared-contract) for the process context.

## Sandbox and presentation

The default harness runs opted-in tools under [`fence`](https://github.com/fencesandbox/fence). Tool policies and platform temp access set the baseline; harness grants extend filesystem access, while policy deny rules still take precedence.

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

`--sandbox-read` and `--sandbox-write` add one-off grants; `--sandbox-auto` adds detected development-tool paths. Setting `sandbox` to `false` runs every tool with user permissions. Grants are frozen into new sessions.

Presentation stays current when a session is reopened:

| Field | Meaning |
| --- | --- |
| `theme_mode` | `auto`, `light`, or `dark` |
| `theme_light`, `theme_dark` | Selected names under `themes` |
| `themes` | Partial named `#RRGGBB` palettes |
| `tui.preview_lines_reasoning` | Collapsed reasoning lines or `"full"` |
| `tui.preview_lines` | Collapsed component-output lines or `"full"` |

`--verbose` temporarily makes both preview limits `"full"`.

## Bundled coding harness

The bundled `default` profile selects `general.md` and `tools.md`, requests up to 16,384 output tokens with medium reasoning effort, and leaves backend and model selection to user configuration or command-line options.

The default harness enables sandboxing, uses the limit defaults above, and exposes:

| Tool | Role |
| --- | --- |
| `read_file` | Read project text with line numbers |
| `edit_file` | Replace exact text and return a diff |
| `write_file` | Create a new text file and return a diff |
| `shell` | Run one zsh command with a timeout |
| `skill` | Load an advertised Agent Skill |
| `search_web` | Search through Exa |
| `fetch_url` | Fetch a page as Markdown through Jina Reader |

Creation hooks record context once:

| Hook | Context |
| --- | --- |
| `project_environment` | Date, platform, project tree, available commands, and skills |
| `git_environment` | Branch or commit, recent commits, and working-tree summary |
| `project_instructions` | `AGENTS.md`, falling back to `CLAUDE.md` |

Most interactive commands are `user_prompt_submit` hooks:

| Input | Action |
| --- | --- |
| `/help`, `/h` | Show harness commands and editor keys |
| `/verbose`, `/v` | Toggle full previews |
| `/new` | Start a session with the active runtime |
| `/copy [N]` | Copy a conversation section |
| `/fork [N]` | Derive a session from a transcript prefix |
| `/sandbox [OP DIR]` | Inspect or update frozen sandbox grants |
| `!COMMAND` | Run a user-authored command and stage its output as context |
| `/resume` | Choose another session for this directory |
| `/compact` | Summarize into a child session |
| `/server` | Hand the session to the experimental browser client |

`git_environment` also runs before ordinary prompts when Git identity changes. Client-owned `/refresh`, `/quit`, and `/queue` commands do not run a turn.

The optional `permission_request` component `review` uses one inference to compare requested risk with user authorization; failures deny. Enable it with `"permission_request":["review"]`.

`/compact` leaves the source unchanged and asks the client to open a summarized child. Automatic compaction may run near a known context-window limit and preserves the interrupted prompt as an editable draft.
