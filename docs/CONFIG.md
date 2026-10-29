# Configuration

Configuration has three homes, each with one job:

| Home | Job | Frozen in a session |
| --- | --- | --- |
| `profiles/NAME.jsonc` | Selects an agent's parts: sandbox files, system prompts, tools, and hooks | Yes |
| `models/NAME.jsonc` | Configures the request: adapter, endpoint, and provider parameters | Yes |
| `sandbox/NAME.jsonc` | Enables sandboxing and grants extra paths | Yes |
| `.env` and the environment | Credentials and core runtime settings | No |

Rendering lives separately in `tui.jsonc`, which merges over [`share/tui.jsonc`](../share/tui.jsonc) and is read fresh on every run.

Configuration is yours: Shellfish bundles components, not profiles, models, or sandbox files. `shellfish init` copies [`share/template/`](../share/template/) into the Shellfish directory as a working starting point, keeping any file that already exists. The bundled [`profile.schema.json`](../share/profile.schema.json), [`model.schema.json`](../share/model.schema.json), [`sandbox.schema.json`](../share/sandbox.schema.json), and [`tui.schema.json`](../share/tui.schema.json) are the exact field references.

## Directories

One Shellfish directory holds everything: profiles, models, sandbox files, components, `tui.jsonc`, `.env`, `sessions/` grouped by project directory, and `scratch/` for private temporary files. Shellfish uses `SHELLFISH_DIR` when set, otherwise the nearest `.shellfish` directory above the working directory, otherwise `~/.shellfish`. A `.shellfish` directory therefore selects a separately configured Shellfish, such as one for work and one for personal projects, for everything beneath it. `--continue` and `--resume` search its sessions. Child agents, hooks, and tools inherit the selection.

## References

Every reference in a profile, model, or sandbox file, and every option that takes one, follows one rule. A reference starting with `/`, `~/`, `./`, `../`, or `@` is a path, where `@` is the bundled root just as `~` is home. A relative path resolves against the file that contains it, or against the working directory on the command line. Anything else is a name, which resolves in its kind's directory, yours first, then bundled. Profile, model, and sandbox names gain `.jsonc`, and a name may be nested, such as `openai/sol`.

Your component therefore shadows the bundled one of the same name, and a path still reaches the bundled one, such as `@tools/shell`. A template profile works in place as `-p @template/profiles/plus.jsonc`, though it names your `sandbox/default.jsonc`. Session headers store bundled paths the same way, so a session survives upgrades.

## Profiles

A profile selects an agent's parts, usually by reference, and supplies their configuration. The model is chosen separately.

```jsonc
// profiles/default.jsonc
{
  "sandbox": "default",
  "system": ["general.md", "tools.md"],
  "tools": ["read_file", "edit_file", "write_file", "shell"],
  "hooks": ["project/environment", "project/instructions", "help", "compact", "sandbox-approver"]
}
```

| Field | Meaning |
| --- | --- |
| `sandbox` | Sandbox files or inline sandbox objects, merged left to right |
| `system` | System prompt files or inline `{"text": "..."}`, concatenated in order |
| `tools` | Tools exposed to the model |
| `hooks` | Hooks, each run by the lifecycle its manifest names, in listed order |
| `config` | Optional object of component-owned settings, grouped by feature |

A lone `sandbox` item needs no list. Inline values let one profile hold everything, though separate files are easier to share.

Only supplied `config` values freeze with the session. Components define their own defaults and validate the settings they consume. Configuration values remain unchanged, including strings that look like paths. Credentials and presentation settings stay external.

`profiles/default.jsonc` is selected when `--profile` is absent and it exists, and `-p REF` selects another. Without either, options alone select the agent's parts. Profiles do not inherit from each other, since a profile is short enough to copy. Only components named in the selected profile are active, and unused files are inert.

Each selection list has an option that appends to the selected profile's list for one session. List options repeat, and any that accept inline values take a JSON object in place of a reference. Repeated `system`, `tools`, and `hooks` references collapse to the first. `sandbox` lists merge in order, so a repeated reference applies again.

| Field | Option |
| --- | --- |
| `sandbox` | `--sandbox REF\|JSON` |
| `system` | `--system REF\|JSON` |
| `tools` | `-t, --tool REF` |
| `hooks` | `--hook REF` |

```sh
shellfish -m default -m '{"request": {"model": "MODEL"}}'  # Try another model name
shellfish --sandbox '{"write": ["./build"]}'           # Grant a directory for one session
shellfish --system ./review.md -t shell_readonly       # Add a prompt and a tool
```

## Models

A model file configures where a request goes and what it carries. `-m REF|JSON` selects one, and `models/default.jsonc` is the model when `-m` is absent.

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
| `config` | Optional object controlling the adapter's exchange, separate from provider request parameters |
| `endpoint` | Overrides the adapter's endpoint |
| `context_window` | Positive capacity override. `null` disables discovery, and absent permits adapter discovery |
| `request` | Provider request parameters, which must include `model` after merging |

`-m` repeats, and its items merge left to right: objects merge recursively and anything else is replaced. A file that names its adapter and model stands alone, and small files can adjust it:

```jsonc
// models/local.jsonc
{"adapter": "openai", "endpoint": "http://127.0.0.1:8080/v1/chat/completions",
 "request": {"model": "local-model"}}

// models/high.jsonc
{"request": {"reasoning": {"effort": "high"}}}
```

```sh
shellfish -m local -m high
```

HTTP adapters share these `model.config` settings, with the following defaults in bundled adapters:

| Setting | Default | Meaning |
| --- | --- | --- |
| `http_timeout` | `3600` | Positive integer seconds per provider request |
| `http_stall` | `300` | Positive integer seconds without response bytes |
| `insecure_tls` | `false` | Boolean that disables TLS certificate verification when true |

For example, `"config": {"http_timeout": 120, "http_stall": 30}` sets shorter limits for a model. The Codex adapter always requires TLS verification.

Bundled adapters: `anthropic`, `codex`, `openai`, `openai-responses`, and `openrouter`. The `openai` adapter works with any OpenAI-compatible endpoint. See [`HARNESS.md`](HARNESS.md#backend-adapters) for the adapter protocol.

Decision models serve `shellfish decide` instead of conversations. Bundled decision adapters: `openai-decisions` for OpenAI's Decisions API, and `systemone` for TypeSafe's System One API with `TYPESAFE_API_KEY`. For oMLX servers, `systemone-omlx` and `openai-decisions-omlx` speak the same formats. They need an endpoint, and they send `OMLX_API_KEY` when set rather than the provider's key. `systemone-omlx` also accepts video:

```jsonc
// models/d3.jsonc
{"adapter": "systemone-omlx", "endpoint": "http://127.0.0.1:8000/v1/systemone",
 "request": {"model": "d3-flash"}}
```

See [`HARNESS.md`](HARNESS.md#decisions) for the decision format.

A new session freezes the selected profile and model in its header: sandbox and model items merged, system prompts joined into one text, and every other reference resolved. The header's `profile` is itself a profile and its `model` a model file, so together they select the same session again. A child agent started by the `agent` tool keeps its parent's model.

## Environment

Credentials and core runtime settings live in exported variables or `.env` in the Shellfish directory. Exported values win. Both stay external and are read for each invocation, so a change applies to existing sessions too.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SHELLFISH_MAX_REQUESTS_PER_TURN` | `100` | Provider requests per turn |
| `SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST` | `25` | Tool calls per response |
| `SHELLFISH_MAX_CAPTURE_BYTES` | `32768` | Bytes kept from each component stream, at least `64`, overridable by a manifest |

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

Tools and hooks require `run`, and backends require `run`, `decide`, or both. An optional `manifest.json` or `manifest.jsonc` supplies configuration, with an absent manifest treated as `{}`. A hook's manifest names its lifecycle with `on`. Tools need model-facing descriptions, input schemas, and execution policies. Backends need an endpoint from either their manifest or a model file. See [`HARNESS.md`](HARNESS.md) for the contracts. References are frozen in the session, while manifest edits affect later invocations only. Missing or invalid active components fail session creation, and an invalid manifest edited later fails the next run.

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
| `user_approval_timeout` | Seconds to wait for the user to approve a sandbox bypass before denying it. Defaults to `120` |
| `read` | Extra read grants |
| `write` | Extra read-write grants |

Grants are paths and need not exist, so one file can serve several machines. A profile's `sandbox` list merges left to right: grants accumulate, and a later `enabled` or `user_approval_timeout` replaces an earlier one. A profile without a `sandbox` list is sandboxed with no extra grants.

`--sandbox` adds a sandbox file or object for one session, and `--sandbox-auto` adds detected development-tool paths. A new session freezes the merged sandbox, and `/sandbox` changes its grants for one session.

## Rendering

`tui.jsonc` is read on every run, so a reopened session renders with whatever it says today.

| Field | Meaning |
| --- | --- |
| `theme_mode` | `auto`, `light`, or `dark` |
| `theme_light`, `theme_dark` | Selected names under `themes` |
| `themes` | Partial named `#RRGGBB` palettes |
| `preview_lines_reasoning` | Collapsed reasoning lines or `"full"` |
| `preview_lines` | Collapsed component-output lines or `"full"` |

`--verbose` temporarily makes both preview limits `"full"`. A hook or tool manifest's `user_preview_lines` overrides the global limit.

## Starter agent

`shellfish init` writes four profiles and the default model, `models/default.jsonc`: the OpenRouter adapter with up to 16,384 output tokens and medium reasoning effort, whose `MODEL` placeholder you replace. Each profile selects `sandbox/default.jsonc`, which grants nothing until you edit it.

It also copies the starter `skill-creator` into `skills/`, where you can edit it. Skills come from the current project's `.agents/skills/` (falling back to `.claude/skills/`), the selected Shellfish directory's `skills/`, and `~/.agents/skills/`, in that precedence order. There is no bundled skill fallback.

Set `"config": {"skills": ["skill-creator", "code-review"]}` in a profile to allow only those skill names. Omit `config.skills` to allow every discovered skill, or use `[]` to allow none. Names are literal, and names not found in the discovery sources are ignored. The filter applies to advertising, the `skill` tool, and explicit `$skill-name` requests. It controls harness availability, not filesystem permissions.

| Profile | Selects |
| --- | --- |
| [`default`](../share/template/profiles/default.jsonc) | `general.md` and `tools.md`, the tools below, and the bundled hooks |
| [`basic`](../share/template/profiles/basic.jsonc) | `default` without web tools or skills |
| [`readonly`](../share/template/profiles/readonly.jsonc) | Read-only file and shell tools |
| [`plus`](../share/template/profiles/plus.jsonc) | `default` with the agent tool and permission review |

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

For ordinary prompts, `$skill-name` loads each matching allowed skill into the model's context before the request, even when `disable-model-invocation` is true. The submitted prompt stays unchanged. Unknown and excluded skill names are ignored.

`/compact` leaves the source unchanged and asks the client to open a summarized child. Automatic compaction preserves the interrupted prompt as an editable draft.

## Optional bundled components

### Agent tool

The `agent` tool lets you delegate a separate task to another agent, so work can proceed independently of your current conversation. You can wait for its result, let it run in the background, check its progress, or give it a follow-up task once it finishes. It is opt-in: the `plus` profile enables it, or add `"agent"` to a profile's `tools`.

Background work returns control after launch. The default limit is four active child agents per parent. Set `"config": {"agent": {"max_active": 2}}` in the parent's profile to choose another positive integer. Supplied limits freeze with the session, and inspection remains available when all slots are occupied.

Inspection distinguishes a child that is still running from one that has stopped without a final transcript outcome. A stopped child releases its active slot and can be continued. Shellfish recovers unfinished work on that next turn. A child killed outright during its stop hooks can appear settled, and those hooks do not run again.

### Sandbox approver hook

The `sandbox-approver` hook helps decide whether a requested sandbox bypass is justified by the user's instructions. It approves or denies each request. If the review itself fails, the request falls back to asking the user. The `plus` profile enables it, but the default profile does not. To enable it in another profile, add `"sandbox-approver"` to its `hooks`.

The reviewer uses the session's model by default. Set `"config": {"sandbox-approver": {"model": "review"}}` in the profile to select another model by name, such as `models/review.jsonc`. The name freezes with the session, but its model file is read on each review. The selection replaces the complete model configuration, so it can use a different backend. Review requests impose their own structured output and output limit, and use a fixed input budget rather than adapting to the model's capacity. An invalid setting, unavailable model, or provider failure asks the user instead.

Set `decision_model` instead of `model` to review with a [decision adapter](HARNESS.md#decisions), such as `{"decision_model": "d3"}`. The decision model rates how likely each risk and authorization level is. The hook allows a request only when it is at least 80% likely that authorization covers the risk, and denies it otherwise. Less decisive models may need a lower bar, such as `"allow_threshold": 0.5`. Run `./tests/run decisions MODEL` to check a model against sample requests. It also denies requests that appear at least 50% likely to be driven by instructions in untrusted data. Denial reasons state these likelihoods. A refusal asks the user, like other review failures.
