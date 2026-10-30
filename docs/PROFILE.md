# Profiles

A profile selects an agent's system prompts, tools, commands, hooks, and sandbox settings. Together these form its harness: the behavior around Shellfish's shared execution loop. The [model](MODELS.md) is selected separately.

See [`CONFIG.md`](CONFIG.md) for setup, directory selection, and reference lookup, and [`COMPONENTS.md`](COMPONENTS.md) for writing tools, commands, and hooks. The [`profile.schema.json`](../share/profile.schema.json) is the exact field reference.

## Selection

`-p REF` or `--profile REF` selects a profile file, and `-p JSON` supplies one inline. Without the option, Shellfish uses your `profiles/default.jsonc`, falling back to the bundled default. Use `-p '{}'` to start with an empty profile and select the agent's parts through command-line options alone.

```jsonc
// profiles/review.jsonc
{
  "sandbox": "default",
  "system": ["general.md", "review.md"],
  "tools": ["read_file", "shell_readonly"],
  "commands": ["help", "compact"],
  "hooks": ["project/instructions"]
}
```

```sh
shellfish -p review
shellfish -p '{"tools": ["read_file"], "system": [{"text": "Review without editing."}]}'
```

| Field | Meaning | Append from the command line |
| --- | --- | --- |
| `sandbox` | Sandbox files or inline objects, merged left to right | `--sandbox REF\|JSON` |
| `system` | Prompt files or inline `{"text": "..."}`, concatenated in order | `--system REF\|JSON` |
| `tools` | Tools exposed to the model | `-t, --tool REF` |
| `commands` | Commands the user runs as `/NAME` instead of submitting a prompt | `--command REF` |
| `hooks` | Hooks run in listed order within their declared lifecycle | `--hook REF` |
| `config` | Component-owned settings, grouped by feature | Supplied in the profile |

A lone `sandbox` item needs no list. Inline values let one profile hold everything, though separate files are easier to share. Profiles do not inherit from each other, since a profile is short enough to copy. Only named components are active, and unused files are inert.

List options repeat and append to the selected profile for one session. Repeated `system`, `tools`, `commands`, and `hooks` references collapse to the first. Sandbox lists merge in order, so a repeated reference applies again.

```sh
shellfish --sandbox '{"write": ["./build"]}'       # Grant a directory for one session
shellfish --system ./review.md -t shell_readonly   # Add a prompt and a tool
```

### Settings and session lifetime

Editing a profile or its prompt files affects new sessions only.

Keep credentials out of `config`. Settings live under a component's name, such as `config.read_file` or `config.sandbox.approver` for the `sandbox/approver` hook, or under a shared feature name such as `config.skills`. Components validate their own settings and supply omitted defaults. Strings that look like paths remain unchanged.

## Sandbox

A tool is sandboxed only when both its manifest and the session enable sandboxing. Shellfish uses [`fence`](https://github.com/fencesandbox/fence), found on `PATH`, with the tool's `fence.jsonc` policy. Otherwise the tool runs with user permissions.

Sandbox files hold standing settings:

```jsonc
// sandbox/default.jsonc
{"read": ["~/.cargo", "~/go/pkg"], "write": ["~/.cache/uv"]}
```

| Field | Meaning |
| --- | --- |
| `enabled` | Defaults to `true`. `false` runs every tool with user permissions |
| `user_approval_timeout` | Seconds to wait for user approval of a sandbox bypass, default `120` |
| `read` | Extra read grants |
| `write` | Extra read-write grants |

Grants are paths and need not exist, so one file can serve several machines. Sandbox lists merge left to right. Grants accumulate, and later `enabled` or `user_approval_timeout` values replace earlier ones. A profile without a sandbox list is sandboxed with no extra grants. See [`sandbox.schema.json`](../share/sandbox.schema.json) for the exact fields.

Tool policies and platform temp access set the baseline. Grants extend access, but policy deny rules still win. A tool policy can `extend` another policy, as `shell_readonly` extends `shell` while denying writes. Bundled policies prevent tools from creating or changing `.shellfish` directories because their contents run outside the sandbox. A `SHELLFISH_DIR` with another name inside a writable path is not protected.

`--sandbox` adds a file or object for one session, and `--sandbox-auto` adds detected development-tool paths. `/sandbox` updates the current session's frozen grants.

### Bypass approval

A sandboxed tool can opt into requesting a bypass with `allow_sandbox_bypass: true`. Shellfish then exposes `request_sandbox_bypass` and `sandbox_bypass_reason` to the model. Both must be supplied together. The tool runs unsandboxed only after a `permission_request` hook or an interactive client approves it.

If every permission hook defers, Shellfish asks the client. Without a client, or after `user_approval_timeout`, it denies the request without invoking the tool. The approval prompt shows the tool's name and raw input. Bypass requests receive a pending, approved, denied, or cancelled badge independently of component display templates.

## Starter agent

The bundled default profile supplies a complete agent without `init`, once you select a model. `shellfish init` copies that profile and its sandbox settings for customization, plus an editable read-only profile and its paired prompt. The general, tools, and sandbox prompts stay bundled unless you override them with your own files.

Both starter profiles select `sandbox/default.jsonc`, whose bundled default grants nothing extra. The default profile includes commented examples for enabling subagents and model-reviewed sandbox bypasses.

| Profile | Selects |
| --- | --- |
| [`default`](../share/profiles/default.jsonc) | Bundled `general.md`, `tools.md`, and `sandbox.md`, the tools below, and the bundled commands and hooks |
| [`readonly`](../share/template/profiles/readonly.jsonc) | Its editable `readonly.md` and bundled `tools.md` and `sandbox.md`, read-only file and shell tools, and a smaller hook list |

| Tool | Role |
| --- | --- |
| `read_file` | Read text with line numbers or view an image, which needs ImageMagick or `sips` |
| `edit_file` | Replace exact text and return a diff |
| `write_file` | Create a text file and return a diff |
| `shell` | Run one zsh command with a timeout |
| `search_web` | Search through Exa |
| `fetch_url` | Fetch a page as Markdown through Jina Reader |
| `skill` | Load an advertised Agent Skill |

`read_file` defaults to WebP at quality 75 and at most 1568 pixels on the long edge. Set `"config": {"read_file": {"image_format": "jpeg", "image_quality": 60, "image_max_edge": 1024}}` to choose `webp`, `jpeg`, or `png`, quality 1 to 100, and a long edge of 1 to 8000 pixels. Smaller images can cost fewer tokens. Without ImageMagick, images needing re-encoding become JPEG when `sips` cannot write the chosen format. An image already in the chosen format and within the size limit is sent unchanged.

The default profile's `session_start` hooks record context once:

| Hook | Context |
| --- | --- |
| `project/environment` | Date, platform, project tree, and available commands |
| `git/environment` | Branch or commit, recent commits, and working-tree summary |
| `project/instructions` | `AGENTS.md`, falling back to `CLAUDE.md` |
| `skills/list` | Skills the `skill` tool can load |

The bundled commands are selected by the profile:

| Input | Action |
| --- | --- |
| `/help`, `/h` | Show the profile's commands and editor keys |
| `/verbose`, `/v` | Toggle full previews |
| `/new` | Start a session with the active profile |
| `/resume` | Choose another session for this directory |
| `/fork [N]` | Derive a session from a transcript prefix |
| `/rewind [N]` | Truncate this session to a transcript prefix |
| `/compact` | Summarize into a child session |
| `/copy [N]` | Copy a conversation section |
| `/user_shell COMMAND`, `/shell` | Run a user-authored command and stage its output as context |
| `/sandbox [OP DIR]` | Inspect or update frozen sandbox grants |

Client-owned `/refresh`, `/quit`, and `/queue` commands do not run a turn. Bundled submission hooks compact automatically near a known context-window limit, report Git identity changes, and load skills before ordinary prompts. `/compact` leaves the source unchanged and opens a summarized child through the client. Its summary shows in full under `/verbose`. Automatic compaction preserves the interrupted prompt as an editable draft.

### Skills

`init` copies the starter `skill-creator` into `skills/`, where you can edit it. Skills come from these sources in precedence order:

1. `.agents/skills/` in the working directory.
2. `skills/` in the selected Shellfish directory.
3. `.agents/skills/` beside that directory, only when it is named `.shellfish`.

With `~/.shellfish`, the last source is `~/.agents/skills/`. A project's `.shellfish` uses that project's `.agents/skills/` instead. There is no bundled skill fallback.

Set `"config": {"skills": ["skill-creator", "code-review"]}` to allow only those literal names. Omit `config.skills` to allow every discovered skill, or use `[]` to allow none. Missing names are ignored. The filter controls advertising, the `skill` tool, and explicit `$skill-name` requests, not filesystem permissions.

With the `skills/mention` hook, `$skill-name` in an ordinary prompt loads matching allowed skills before inference, including user-only skills with `disable-model-invocation: true`. The submitted prompt stays unchanged. Unknown and excluded names are ignored.

## Optional bundled components

### Subagents

Add `"subagent"` to a profile's `tools` to delegate separate tasks. A subagent can fork the conversation or start fresh, run in the background, report progress, and accept a follow-up task after finishing.

Both modes use the parent's profile and model unless a fresh start selects alternatives you offer. The model sees only the choices and descriptions in the parent's config:

```jsonc
"config": {"subagent": {
  "profiles": {"readonly": "Investigate and answer questions without changing files"},
  "models": {"fast": "A cheaper model for simple lookups"},
  "max_active": 4
}}
```

Without the choice lists, every subagent uses the parent's profile and model. Subagents cannot launch their own subagents. `max_active` is a positive integer, default `4`, limiting running subagents per parent. A subagent holds its slot only while its turn runs. Supplied settings freeze with the session.

Background work returns control after launch. Inspection distinguishes running work from a stopped subagent without a final outcome. Continuing a stopped subagent recovers unfinished work. A subagent killed during its stop hooks can appear settled, and those hooks do not run again.

### Sandbox approver

Add `"sandbox/approver"` to a profile's `hooks` to have a model review bypass requests against the user's instructions. It approves or denies each request. Review failures fall back to asking the user.

The reviewer uses the session's model by default. Set `"config": {"sandbox": {"approver": {"model": "review"}}}` to select another model by name. The name freezes, but the model file is read on each review and replaces the complete model configuration, including the provider. Review requests impose their own structured output, output limit, and fixed input budget. The reviewer sees the system prompt, startup context, latest user message, and as much of the current turn as fits, with older tool output shortened. Set `"max_input_kb": 48` to raise the default 24 KB budget for larger or faster review models. Invalid settings, unavailable models, and provider failures ask the user instead. Set `http_timeout` in the review model's `config` to bound how long a review can wait before asking the user.

Set `decision_model` instead of `model` to use a [decision provider](MODELS.md#decisions), such as `{"decision_model": "d3"}`. It approves when authorization is at least 80% likely to cover the risk, and denies otherwise. Set `"allow_threshold": 0.5` to lower that bar. It also denies requests at least 50% likely to be driven by untrusted instructions. Denial reasons include these likelihoods. A refusal asks the user. Run `./tests/run decisions MODEL` to evaluate a model on sample requests.
