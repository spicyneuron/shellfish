# Configuration

Configuration has three homes, each with one job:

| Home | Job | Frozen in a session |
| --- | --- | --- |
| `profiles/NAME.jsonc` | Selects an agent's parts: model and sandbox files, system prompts, tools, and hooks | Yes |
| `models/NAME.jsonc` | Configures the request: adapter, endpoint, and provider parameters | Yes |
| `sandbox/NAME.jsonc` | Enables sandboxing and grants extra paths | Yes |
| `.env` and the environment | Credentials and settings for Shellfish and its components | No |

Rendering lives separately in `tui.jsonc`, which merges over [`share/tui.jsonc`](../share/tui.jsonc) and is read fresh on every run.

Copy [`share/template/`](../share/template/) into the Shellfish directory for a working starting point. The bundled [`profile.schema.json`](../share/profile.schema.json), [`model.schema.json`](../share/model.schema.json), [`sandbox.schema.json`](../share/sandbox.schema.json), and [`tui.schema.json`](../share/tui.schema.json) are the exact field references.

## Directories

One Shellfish directory holds everything: profiles, models, sandbox files, components, `tui.jsonc`, `.env`, `sessions/` grouped by project directory, and `scratch/` for private temporary files. Shellfish uses `SHELLFISH_DIR` when set, otherwise the nearest `.shellfish` directory above the working directory, otherwise `~/.shellfish`. A `.shellfish` directory therefore selects a separately configured Shellfish, such as one for work and one for personal projects, for everything beneath it. `--continue` and `--resume` search its sessions. Child agents, hooks, and tools inherit the selection.

## References

Every reference in a profile, model, or sandbox file, and every option that takes one, follows one rule. A reference starting with `/`, `~/`, `./`, `../`, or `@` is a path, where `@` is the bundled root just as `~` is home. A relative path resolves against the file that contains it, or against the working directory on the command line. Anything else is a name, which resolves in its kind's directory, yours first, then bundled. Profile, model, and sandbox names gain `.jsonc`, and a name may be nested, such as `openai/sol`.

Your file therefore shadows the bundled file of the same name, and a path still reaches the bundled one: `@tools/shell`, or `-p @profiles/coding.jsonc`. Session headers store bundled paths the same way, so a session survives upgrades.

Path options such as `--system-file` and `--sandbox-read` resolve any other path against the working directory.

## Profiles

A profile only selects. It holds no values of its own.

```jsonc
// profiles/default.jsonc
{
  "model": ["openrouter", "default"],
  "sandbox": ["default"],
  "system": ["general.md", "tools.md"],
  "tools": ["read_file", "edit_file", "write_file", "shell"],
  "hooks": ["project/environment", "project/instructions", "help", "compact", "review"]
}
```

| Field | Meaning |
| --- | --- |
| `model` | Model files, merged left to right |
| `sandbox` | Sandbox files, merged left to right |
| `system` | System prompt files, concatenated in order |
| `tools` | Tools exposed to the model |
| `hooks` | Hooks, each run by the lifecycle its manifest names, in listed order |

`profiles/default.jsonc` is selected when `--profile` is absent, and `-p REF` selects another. Profiles do not inherit from each other, since a profile is short enough to copy. Only components named in the selected profile are active, and unused files are inert.

## Models

A model file configures where a request goes and what it carries.

```jsonc
// models/work.jsonc
{
  "adapter": "anthropic",
  "request": {"model": "claude-opus-4-1", "max_tokens": 16384}
}
```

| Field | Meaning |
| --- | --- |
| `adapter` | Backend adapter reference |
| `endpoint` | Overrides the adapter's endpoint |
| `context_window` | Positive capacity override. `null` disables discovery, and absent permits adapter discovery |
| `request` | Provider request parameters, which must include `model` after merging |

A profile's `model` list merges left to right: objects merge recursively and anything else is replaced. That lets small model files share settings without repeating them, including bundled ones:

```jsonc
// models/local.jsonc
{"adapter": "openai", "endpoint": "http://127.0.0.1:8080/v1/chat/completions"}

// models/high.jsonc
{"request": {"reasoning": {"effort": "high"}}}

// profiles/local.jsonc
{"model": ["openrouter", "local", "high"], "system": ["general.md"], "tools": ["shell"]}
```

`-m REF` merges another model file over the profile's list for one session and may repeat. `--request JSON` merges raw parameters last, so `--request '{"model":"MODEL"}'` tries a model without a file.

Bundled adapters: `anthropic`, `codex`, `openai`, `openai-responses`, and `openrouter`. The `openai` adapter works with any OpenAI-compatible endpoint. See [`HARNESS.md`](HARNESS.md#backend-adapters) for the adapter protocol.

A new session freezes the selected profile with its merged model and every reference resolved.

## Environment

Credentials and settings live in exported variables or `.env` in the Shellfish directory. Exported values win. Both stay external and are read for each invocation, so a change applies to existing sessions too.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SHELLFISH_MAX_REQUESTS_PER_TURN` | `100` | Provider requests per turn |
| `SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST` | `25` | Tool calls per response |
| `SHELLFISH_MAX_CAPTURE_BYTES` | `32768` | Bytes kept from each component stream, at least `64`, overridable by a manifest |
| `SHELLFISH_HTTP_TIMEOUT` | `3600` | Seconds per provider request |
| `SHELLFISH_HTTP_STALL` | `300` | Seconds without response bytes |
| `SHELLFISH_INSECURE_TLS` | `0` | `1` skips TLS verification |
| `SHELLFISH_MAX_ACTIVE_AGENTS` | `4` | Active child agents per parent |

Hooks and adapters are trusted: they inherit the process environment and receive every `.env` value. Tools receive only the names their manifest declares. Unsandboxed tools also inherit the process environment; sandboxed tools start clean. A key kept only in `.env` is therefore invisible to tools that do not declare it. See [`HARNESS.md`](HARNESS.md#shared-contract) for the process context.

## Components

A configuration root has separate locations for each kind:

```text
profiles/NAME.jsonc
models/NAME.jsonc
sandbox/NAME.jsonc
system/FILE.md
tools/TOOL/
hooks/HOOK/
backends/ADAPTER/
```

Executable components require `run`. An optional `manifest.json` or `manifest.jsonc` supplies configuration, with an absent manifest treated as `{}`. A hook's manifest names its lifecycle with `on`. Tools need model-facing descriptions, input schemas, and execution policies. Backends need an endpoint from either their manifest or a model file. See [`HARNESS.md`](HARNESS.md) for the contracts. References are frozen in the session, while manifest edits affect later invocations only. Missing or invalid active components fail resolution.

## Sandbox

The default harness runs opted-in tools under [`fence`](https://github.com/fencesandbox/fence). Tool policies and platform temp access set the baseline; grants extend filesystem access, while policy deny rules still take precedence. Bundled policies never let a tool create or change a `.shellfish` directory, since its contents run outside the sandbox. A `SHELLFISH_DIR` with another name inside a writable path is not protected.

Sandbox files hold standing settings:

```jsonc
// sandbox/default.jsonc
{"read": ["~/.cargo", "~/go/pkg"], "write": ["~/.cache/uv"]}
```

| Field | Meaning |
| --- | --- |
| `enabled` | `false` runs every tool with user permissions. Defaults to `true` |
| `read` | Extra read grants |
| `write` | Extra read-write grants |

Grants are paths and need not exist, so one file can serve several machines. A profile's `sandbox` list merges left to right: grants accumulate, and a later `enabled` replaces an earlier one. A profile without a `sandbox` list is sandboxed with no extra grants.

`--sandbox-read` and `--sandbox-write` add one-off grants, and `--sandbox-auto` adds detected development-tool paths. A new session freezes the merged grants, and `/sandbox` changes them for one session.

## Rendering

`tui.jsonc` is read on every run, so a reopened session renders with whatever it says today.

| Field | Meaning |
| --- | --- |
| `theme_mode` | `auto`, `light`, or `dark` |
| `theme_light`, `theme_dark` | Selected names under `themes` |
| `themes` | Partial named `#RRGGBB` palettes |
| `preview_lines_reasoning` | Collapsed reasoning lines or `"full"` |
| `preview_lines` | Collapsed component-output lines or `"full"` |

`--verbose` temporarily makes both preview limits `"full"`. A hook or tool manifest's `user_preview_lines` overrides the global limit for Running and settled text.

## Bundled agent

The bundled [`default`](../share/profiles/default.jsonc) profile selects `general.md` and `tools.md`, the tools below, and the bundled hooks. Its model list is the bundled [`openrouter`](../share/models/openrouter.jsonc) model, with up to 16,384 output tokens and medium reasoning effort, followed by your `models/default.jsonc`, which must name a model. Its sandbox list is your `sandbox/default.jsonc`, which is empty until you write one:

```jsonc
// models/default.jsonc
{"request": {"model": "anthropic/claude-opus-4.1"}}
```

[`coding`](../share/profiles/coding.jsonc) adds permission review.

| Tool | Role |
| --- | --- |
| `read_file` | Read project text with line numbers |
| `edit_file` | Replace exact text and return a diff |
| `write_file` | Create a new text file and return a diff |
| `shell` | Run one zsh command with a timeout |
| `skill` | Load an advertised Agent Skill |
| `search_web` | Search through Exa |
| `fetch_url` | Fetch a page as Markdown through Jina Reader |

The bundled `session_start` hooks record context once, one block per part:

| Hook | Context |
| --- | --- |
| `project/environment` | Date, platform, project tree, available commands, and skills |
| `git/environment` | Branch or commit, recent commits, and working-tree summary |
| `project/instructions` | `AGENTS.md`, falling back to `CLAUDE.md` |

The bundled `user_prompt_submit` hooks handle interactive commands:

| Input | Action |
| --- | --- |
| `/help`, `/h` | Show harness commands and editor keys |
| `/verbose`, `/v` | Toggle full previews |
| `/new` | Start a session with the active profile |
| `/copy [N]` | Copy a conversation section |
| `/fork [N]` | Derive a session from a transcript prefix |
| `/sandbox [OP DIR]` | Inspect or update frozen sandbox grants |
| `!COMMAND` | Run a user-authored command and stage its output as context |
| `$SKILL` | Load a matching skill into model context, including user-only skills |
| `/resume` | Choose another session for this directory |
| `/compact` | Summarize into a child session |
| `/server` | Hand the session to the experimental browser client |

It also compacts automatically near a known context-window limit and reports Git identity changes before ordinary prompts. Client-owned `/refresh`, `/quit`, and `/queue` commands do not run a turn.

For ordinary prompts, `$skill-name` loads each matching skill into the model's context before the request, even when `disable-model-invocation` is true. The submitted prompt stays unchanged. Unknown skill names are ignored.

`/compact` leaves the source unchanged and asks the client to open a summarized child. Automatic compaction preserves the interrupted prompt as an editable draft.

## Optional bundled components

### Agent tool

The `agent` tool lets you delegate a separate task to another agent, so work can proceed independently of your current conversation. You can wait for its result, let it run in the background, check its progress, or give it a follow-up task once it finishes. It is opt-in; add `"agent"` to a profile's `tools`.

Background work returns control after launch; the default limit is four active child agents per parent, set by `SHELLFISH_MAX_ACTIVE_AGENTS`. Inspection distinguishes a child that is still running from one that has stopped without a final transcript outcome. A stopped child releases its active slot and can be continued; Shellfish recovers unfinished work on that next turn.

### Review hook

The `review` hook helps decide whether a requested sandbox bypass is justified by the user's instructions. If it cannot approve the request, the bypass is denied and the tool is not run. The bundled `coding` profile enables it, but the default profile does not. To enable it in another profile, add `"review"` to its `hooks`.
