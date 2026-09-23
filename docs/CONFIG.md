# Configuration

Shellfish reads JSONC from `$XDG_CONFIG_HOME/shellfish/` (or `~/.config/shellfish/` when `XDG_CONFIG_HOME` is unset). `profiles/NAME.jsonc` describes a runtime and `tui.jsonc` describes rendering. A profile name resolves to exactly one file: yours shadows the bundled file of the same name under [`share/default/profiles/`](../share/default/profiles/). `tui.jsonc` merges over [`share/default/tui.jsonc`](../share/default/tui.jsonc).

The two never mix. A session freezes a runtime, so a profile rejects rendering keys; `tui.jsonc` is read fresh on every run and is never frozen.

Copy [`share/template/`](../share/template/) into that directory for a working starting point. The bundled [`shellfish.schema.json`](../share/shellfish.schema.json) and [`tui.schema.json`](../share/tui.schema.json) are the exact field references.

## Profiles

`profiles/default.jsonc` is selected when `--profile` is absent. `-p NAME` selects another and repeats compose: `-p review -p readonly` merges them left to right. A file you write shadows the bundled file of that name, and `@NAME` always means the bundled file, so your own `default.jsonc` can extend `@default` to build on the bundled agent.

A profile's top level is the runtime's top level.

```jsonc
// profiles/work.jsonc
{
  "extend": ["default"],
  "backend": {"adapter": "openrouter"},
  "harness": {"tools": ["...", "my_tool"]},
  "request": {"model": "MODEL"}
}
```

| Profile field | Meaning |
| --- | --- |
| `extend` | Ordered profile names, merged left to right; own keys last |
| `backend` | Adapter reference and transport settings |
| `harness` | Tools, hooks, sandbox policy, and turn limits |
| `system` | Ordered system-component references |
| `request` | Provider request object; `model` is required after resolution |
| `context_window` | Positive capacity override; `null` disables discovery; absent permits adapter discovery |

The selected profiles and everything they extend are flattened into one list, parents first and each profile once, then merged in order. Objects merge recursively and arrays replace, except that `"..."` splices the list as it stood before that profile, so a list can be extended without restating it. Cycles are errors. A resolved new session must have an adapter and a valid model.

A profile that sets only one section is a shareable fragment; that is what `extend` is for, so there are no separate backend or harness maps.

```jsonc
// profiles/local-llm.jsonc — not selectable on its own; no model
{"backend": {"adapter": "openai",
             "endpoint": "http://127.0.0.1:8080/v1/chat/completions",
             "environment": []}}

// profiles/local.jsonc
{"extend": ["default", "local-llm"], "request": {"model": "qwen3"}}
```

A fragment that omits `environment` inherits the previous layer's credential names, so state it explicitly.

## Backend

| Field | Default / meaning |
| --- | --- |
| `adapter` | Adapter reference; `-b REF` overrides it |
| `endpoint` | Adapter manifest endpoint |
| `environment` | Adapter manifest declarations |
| `insecure_tls` | `false` |
| `http_timeout` | `3600` seconds |
| `http_stall` | `300` seconds without response bytes |

Bundled adapters: `anthropic`, `codex`, `openai`, `openai-responses`, and `openrouter`. See [`HARNESS.md`](HARNESS.md#backend-adapters) for the adapter protocol.

## Harness

Omitted hook and tool lists are empty; omitted sandbox and limit fields use the defaults below.

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

One capability set can serve different roles, because the system prompt sits beside it:

```jsonc
// profiles/review.jsonc
{
  "extend": ["default"],
  "harness": {
    "tools": ["read_file"],
    "session_start": ["project_environment", "project_instructions"]
  },
  "system": ["review.md"]
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

Component manifests declare environment variable names. Values resolve from exported variables first, then `.env` in the configuration directory; missing values remain unset. The names and the directory are frozen, but values remain external and are read for each invocation.

Hooks and adapters inherit the ordinary process environment after every component-declared name is removed, then receive their own selected values. Unsandboxed tools inherit the same filtered environment; sandboxed tools start clean. See [`HARNESS.md`](HARNESS.md#shared-contract) for the process context.

## Sandbox

The default harness runs opted-in tools under [`fence`](https://github.com/fencesandbox/fence). Tool policies and platform temp access set the baseline; harness grants extend filesystem access, while policy deny rules still take precedence.

```jsonc
{
  "extend": ["default"],
  "harness": {
    "sandbox_read_paths": ["/path/to/reference"],
    "sandbox_write_paths": ["/path/to/output"]
  }
}
```

`--sandbox-read` and `--sandbox-write` add one-off grants; `--sandbox-auto` adds detected development-tool paths. Setting `sandbox` to `false` runs every tool with user permissions. Grants are frozen into new sessions.

## Rendering

`tui.jsonc` is read on every run, so a reopened session renders with whatever it says today.

| Field | Meaning |
| --- | --- |
| `theme_mode` | `auto`, `light`, or `dark` |
| `theme_light`, `theme_dark` | Selected names under `themes` |
| `themes` | Partial named `#RRGGBB` palettes |
| `preview_lines_reasoning` | Collapsed reasoning lines or `"full"` |
| `preview_lines` | Collapsed component-output lines or `"full"` |

`--verbose` temporarily makes both preview limits `"full"`. A tool or hook overrides the global limit with `render.preview_lines`; see [`HARNESS.md`](HARNESS.md#rendering).

## Bundled agent

[`profiles/default.jsonc`](../share/default/profiles/default.jsonc) works out of the box: the `openrouter` adapter, `general.md` and `tools.md`, and up to 16,384 output tokens with medium reasoning effort. It sets no model, so supply one in your own profile or with `-m`. [`profiles/coding.jsonc`](../share/default/profiles/coding.jsonc) is a short example of overriding it.

Its harness enables sandboxing, uses the limit defaults above, and exposes:

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

The optional `permission_request` component `review` uses one inference to compare requested risk with user authorization; failures deny. Enable it with `"harness": {"permission_request": ["review"]}`.

`/compact` leaves the source unchanged and asks the client to open a summarized child. Automatic compaction may run near a known context-window limit and preserves the interrupted prompt as an editable draft.
