# Configuration

Shellfish reads JSONC from `$XDG_CONFIG_HOME/shellfish/` (or `~/.config/shellfish/` when `XDG_CONFIG_HOME` is unset). `profiles/NAME/profile.jsonc` describes a runtime and `tui.jsonc` describes rendering. A profile name resolves to exactly one folder: yours shadows the bundled folder of the same name under [`share/profiles/`](../share/profiles/). `tui.jsonc` merges over [`share/tui.jsonc`](../share/tui.jsonc).

The two never mix. A session freezes a runtime, so a profile rejects rendering keys; `tui.jsonc` is read fresh on every run and is never frozen.

Copy [`share/template/`](../share/template/) into that directory for a working starting point. The bundled [`shellfish.schema.json`](../share/shellfish.schema.json) and [`tui.schema.json`](../share/tui.schema.json) are the exact field references.

## Profiles

`profiles/default/` is selected when `--profile` is absent. `-p NAME` selects another and repeats compose: `-p review -p readonly` merges them left to right. A folder you write shadows the bundled folder of that name, and `@NAME` always means the bundled folder, so your own `default` can extend `@default` to build on the bundled agent.

A profile's top level is the runtime's top level.

```jsonc
// profiles/work/profile.jsonc
{
  "extend": ["default"],
  "backend": {"adapter": "openrouter"},
  "tools": ["...", "my_tool"],
  "request": {"model": "MODEL"}
}
```

| Profile field | Meaning |
| --- | --- |
| `extend` | Ordered profile names, merged left to right; own keys last |
| `backend` | Adapter reference and transport settings |
| `tools`, `hooks`, sandbox, and limits | The harness; see [Harness](#harness) |
| `system` | Ordered system-component references |
| `request` | Provider request object; `model` is required after resolution |
| `context_window` | Positive capacity override; `null` disables discovery; absent permits adapter discovery |

The selected profiles and everything they extend are flattened into one list, parents first and each profile once, then merged in order. Objects merge recursively and arrays replace, except that `"..."` splices the list as it stood before that profile, so a list can be extended without restating it. Cycles are errors. A resolved new session must have an adapter and a valid model.

A profile that sets only one section is a shareable fragment; that is what `extend` is for, so there are no separate backend or harness maps.

```jsonc
// profiles/local-llm/profile.jsonc — not selectable on its own; no model
{"backend": {"adapter": "openai",
             "endpoint": "http://127.0.0.1:8080/v1/chat/completions"}}

// profiles/local/profile.jsonc
{"extend": ["default", "local-llm"], "request": {"model": "qwen3"}}
```

## Backend

| Field | Default / meaning |
| --- | --- |
| `adapter` | Adapter reference; `-b REF` overrides it |
| `endpoint` | Adapter manifest endpoint |
| `insecure_tls` | `false` |
| `http_timeout` | `3600` seconds |
| `http_stall` | `300` seconds without response bytes |

Bundled adapters: `anthropic`, `codex`, `openai`, `openai-responses`, and `openrouter`. See [`HARNESS.md`](HARNESS.md#backend-adapters) for the adapter protocol.

## Harness

These fields sit at the profile's top level. Omitted hook and tool lists are empty; omitted sandbox and limit fields use the defaults below.

| Field | Default / meaning |
| --- | --- |
| `tools` | `[]`; unique tool references exposed to the model |
| `hooks.session_start` | `[]`; creation context hooks |
| `hooks.user_prompt_submit` | `[]`; prompt gates and interactive commands |
| `hooks.permission_request` | `[]`; sandbox-bypass decisions |
| `hooks.pre_tool_use` | `[]`; tool policy gates |
| `hooks.post_tool_use` | `[]`; post-execution observers |
| `hooks.stop` | `[]`; completion gates |
| `sandbox` | `true` |
| `sandbox_read_paths` | `[]`; extra read grants |
| `sandbox_write_paths` | `[]`; extra read-write grants |
| `max_requests_per_turn` | `100` |
| `max_tool_calls_per_request` | `25` |
| `max_capture_bytes` | `32768`; per component execution, minimum `64` |

One capability set can serve different roles, because the system prompt sits beside it:

```jsonc
// profiles/review/profile.jsonc, beside system/review.md
{
  "extend": ["default"],
  "tools": ["read_file"],
  "hooks": {"session_start": ["project_environment", "project_instructions"]},
  "system": ["review.md"]
}
```

## Components and environment

A profile folder keeps its components beside `profile.jsonc`:

```text
profiles/NAME/
  profile.jsonc
  system/FILE.md
  tools/TOOL/
  hooks/HOOK/NAME/
  backends/ADAPTER/
```

A name in `system`, `tools`, `hooks`, or `backend.adapter` resolves to the first folder that contains it, starting with the most-derived profile and walking back through what it extends; a later `-p` comes before an earlier one. So a profile shadows its parents' components, and a name never falls back beyond those folders: a profile that does not extend `default` references bundled parts as `@default/tools/shell`. `@NAME/path` always resolves inside the bundled folder, while `~/path` and absolute paths are used as written.

Credentials live in exported variables or `.env` in the configuration directory; exported values win. Values remain external and are read for each invocation.

Hooks and adapters are trusted: they inherit the process environment and receive every `.env` value. Tools receive only the `.env` names their manifest declares. Unsandboxed tools also inherit the process environment; sandboxed tools start clean. A key kept only in `.env` is therefore invisible to tools that do not declare it. See [`HARNESS.md`](HARNESS.md#shared-contract) for the process context.

## Sandbox

The default harness runs opted-in tools under [`fence`](https://github.com/fencesandbox/fence). Tool policies and platform temp access set the baseline; harness grants extend filesystem access, while policy deny rules still take precedence.

```jsonc
{
  "extend": ["default"],
  "sandbox_read_paths": ["/path/to/reference"],
  "sandbox_write_paths": ["/path/to/output"]
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

`--verbose` temporarily makes both preview limits `"full"`. A tool's `render.preview_lines` or a hook's `user_preview_lines` overrides the global limit; see [`HARNESS.md`](HARNESS.md).

## Bundled agent

[`default`](../share/profiles/default/profile.jsonc) works out of the box: the `openrouter` adapter, `general.md` and `tools.md`, and up to 16,384 output tokens with medium reasoning effort. It sets no model, so supply one in your own profile or with `-m`. [`coding`](../share/profiles/coding/profile.jsonc) is a short example of overriding it.

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

The optional `permission_request` component `review` uses one inference to compare requested risk with user authorization; failures deny. Enable it with `"hooks": {"permission_request": ["review"]}`.

`/compact` leaves the source unchanged and asks the client to open a summarized child. Automatic compaction may run near a known context-window limit and preserves the interrupted prompt as an editable draft.
