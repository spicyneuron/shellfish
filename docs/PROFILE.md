# Profiles

A profile selects an agent's system prompts, tools, commands, hooks, and sandbox settings. Together these form its harness: the behavior around Shellfish's shared execution loop. The [model](MODELS.md) is selected separately.

See [`CONFIG.md`](CONFIG.md) for setup, directory selection, and reference lookup, and [`COMPONENTS.md`](COMPONENTS.md) for writing tools, commands, and hooks. The [`profile.schema.json`](../share/profile.schema.json) is the exact field reference.

## Selection

`-p REF` or `--profile REF` selects a profile file, and `-p JSON` supplies one inline. Without the option, Shellfish uses your `profiles/default.jsonc`, falling back to the bundled default. Use `-p '{}'` to start with an empty profile and select the agent's parts through command-line options alone.

```jsonc
// profiles/review.jsonc
{
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
| `sandbox` | Sandbox settings and per-tool policies | `--sandbox JSON` |
| `system` | Prompt files or inline `{"text": "..."}`, concatenated in order | `--system REF\|JSON` |
| `tools` | Tools exposed to the model | `-t, --tool REF` |
| `commands` | Commands the user runs as `/NAME` instead of submitting a prompt | `--command REF` |
| `hooks` | Hooks run in listed order within their declared lifecycle | `--hook REF` |
| `config` | Component-owned settings, grouped by feature | Supplied in the profile |

Sandbox settings live directly in the profile. Profiles do not inherit from each other, since a profile is short enough to copy. Only named components are active, and unused files are inert.

List options repeat and append to the selected profile for one session. Repeated `system`, `tools`, `commands`, and `hooks` references collapse to the first.

```sh
shellfish --sandbox '{"tools":{"shell":{"filesystem":{"allowWrite":["./build"]}}}}'
shellfish --system ./review.md -t shell_readonly                   # Add a prompt and a tool
```

### Settings and session lifetime

Editing a profile or its prompt files affects new sessions only.

Keep credentials out of `config`. Settings live under a component's name, such as `config.read_file` or `config.sandbox.approver` for the `sandbox/approver` hook, or under a shared feature name such as `config.skills`. Components validate their own settings and supply omitted defaults. Strings that look like paths remain unchanged.

## Sandbox

A tool is sandboxed only when both its manifest and the session enable sandboxing. Shellfish uses [`fence`](https://github.com/fencesandbox/fence), found on `PATH`, with the tool's `fence.jsonc` policy. Otherwise the tool runs with user permissions.

The profile's `sandbox` object holds standing settings:

```jsonc
"sandbox": {
  "tools": {
    "shell": {
      "filesystem": {
        "allowRead": ["~/.cargo", "~/go/pkg"],
        "allowWrite": ["~/.cache/uv"]
      },
      "network": {"allowedDomains": ["github.com", "*.npmjs.org"]}
    },
    "read_file": {"filesystem": {"allowRead": ["~/reference"]}}
  }
}
```

| Field | Meaning |
| --- | --- |
| `enabled` | Defaults to `true`. `false` runs every tool with user permissions |
| `user_approval_timeout` | Seconds to wait for user approval of a sandbox request, default `120` |
| `tools.NAME` | A [Fence configuration](https://github.com/fencesandbox/fence/blob/main/docs/configuration.md) for the selected tool |
| `tools.NAME.replace` | Defaults to `false`. Set `true` to replace the tool's policy instead of extending it |

Each tool receives only its own policy, keyed by its selected name, such as `shell` or `read_file`. Policies cannot target unselected tools, tools whose manifest disables sandboxing, or `*`. Paths need not exist, so one profile can serve several machines. Explicit `./` and `../` paths resolve against the profile's directory, while `.` and bare Fence patterns are relative to the session directory. A profile without sandbox settings uses the tool policies plus Shellfish's runtime access described below. See [`profile.schema.json`](../share/profile.schema.json) for Shellfish settings and Fence's documentation for policy fields.

By default, your configuration extends the tool's policy using Fence's native merge rules: lists append and deduplicate, ordinary booleans combine with OR, and optional settings such as `command.useDefaults` override when supplied. Empty lists do not clear inherited rules. Deny rules still win over access grants.

To remove or narrow bundled denies, use `replace: true` and supply the policy you want. Omitted fields use Fence's defaults, not the bundled tool's defaults:

```jsonc
"shell": {
  "replace": true,
  "filesystem": {
    "defaultDenyRead": true,
    "allowRead": ["."],
    "allowWrite": ["."],
    "denyRead": ["**/*.key", "**/*.pem"],
    "denyWrite": ["**/.shellfish", "**/.shellfish/**"]
  },
  "command": {"useDefaults": true}
}
```

In a profile, Fence's `extends` requires `replace: true` and can share configuration files or templates. Fence's mandatory protections remain in force, and tools retain platform temporary-directory access and read access to the installed `share/lib/` helpers, subject to policy deny rules. Bundled policies block writes to `.shellfish` directories because their contents run outside the sandbox. Replacing those policies can remove that protection. A `SHELLFISH_DIR` with another name inside a writable path is not protected.

`network.allowedDomains` accepts Fence's hostname patterns, including `*`. Allowing every domain relaxes network isolation, so prefer specific hosts. Local binding and outbound access remain separate Fence settings.

`--sandbox JSON` takes the contents of the profile's `sandbox` object for one session. Repeated options accumulate lists per tool and replace scalar settings with later values. `replace` controls inheritance from the tool's policy, not whether earlier command-line options are discarded.

`/sandbox` lists configured policies grouped by selected tool, and `/sandbox shell` inspects one tool. `/sandbox shell +read ~/reference` adds to `filesystem.allowRead`, and `/sandbox shell +domain github.com` adds to `network.allowedDomains`. Use `-read` or `-domain` to remove a session addition. These commands update the frozen profile, preserving `replace` and other policy settings. They do not change the source configuration or the tool's baseline policy.

### Sandbox access approval

Every sandboxed tool lets the model request specific access with `request_sandbox_access`, naming `read` or `write` directories or `domains` and a `reason`. Relative paths resolve against the session directory. Approved access keeps the call sandboxed. Calls that omit the request run sandboxed without approval.

A tool with `allow_sandbox_bypass: true` also permits `unrestricted: true` in that same object, with a reason and no listed access. Approval runs only that call outside the sandbox. Unrestricted access cannot be approved for the session.

The approval prompt appears immediately and shows the operation alongside the requested access, with paths resolved against the session directory. Permission review hooks run alongside it. Your answer takes priority and cancels an unfinished review. Otherwise, a reviewer's verdict applies ten seconds after it arrives. Pressing another key takes control, so no verdict applies and the full `user_approval_timeout` restarts. If reviewers defer or fail, the prompt waits for your decision. Unanswered prompts are denied after `user_approval_timeout`. Without an interactive client, reviewer decisions apply immediately; without a decision, access is denied.

The user can approve specific access for the rest of the session, which adds it to the session's grants as `/sandbox` would and tells the model it can reuse that access. Later requests ask only for access not already granted to that tool. Unrestricted execution always requires a fresh approval, and reviewers approve only one call. Requests receive a pending, approved, denied, or cancelled badge independently of component display templates.

## Starter agent

The bundled default profile supplies the agent below. See [Setup](CONFIG.md#setup) to install editable starter configuration.

Both starter profiles enable sandboxing with no extra grants. The default profile includes commented examples for enabling subagents and model-reviewed sandbox access requests.

| Profile | Selects |
| --- | --- |
| [`default`](../share/profiles/default.jsonc) | Bundled `general.md`, `tools.md`, and `sandbox.md`, the tools below, and the bundled commands and hooks |
| [`readonly`](../share/template/profiles/readonly.jsonc) | Its editable `readonly.md` and bundled `tools.md` and `sandbox.md`, read-only file and shell tools, and a smaller hook list |

| Tool | Role |
| --- | --- |
| `read_file` | Read text with line numbers or view an image, which needs ImageMagick or `sips` |
| `edit_file` | Replace exact text and return a diff |
| `write_file` | Create or overwrite a text file and return a diff |
| `shell` | Run one zsh command with a timeout |
| `search_web` | Search through Exa |
| `fetch_url` | Fetch a page as Markdown through Jina Reader |
| `skill` | Load an advertised Agent Skill |

`read_file` defaults to WebP at quality 75 and at most 2000 pixels on the long edge. Set `"config": {"read_file": {"image_format": "jpeg", "image_quality": 60, "image_max_edge": 1024}}` to choose `webp`, `jpeg`, or `png`, quality 1 to 100, and a long edge of 1 to 8000 pixels. Smaller images can cost fewer tokens. Anthropic refuses images over 2000 pixels on a side once a request holds more than 20 images, so a larger limit can break long sessions. Without ImageMagick, images needing re-encoding become JPEG when `sips` cannot write the chosen format. An image already in the chosen format and within the size limit is sent unchanged.

The default profile's `session_start` hooks record context once:

| Hook | Context |
| --- | --- |
| `project/environment` | Date, platform, project tree, and available commands |
| `git/environment` | Branch or commit, recent commits, and working-tree summary |
| `project/instructions` | `AGENTS.md`, falling back to `CLAUDE.md` |
| `skills/list` | Skills the `skill` tool can load |
| `sandbox/grants` | Initial per-tool read, write, and domain grants, or a notice that sandboxing is disabled |

The bundled commands are selected by the profile:

| Input | Action |
| --- | --- |
| `/help`, `/h` | Show the profile's commands and editor keys |
| `/new` | Start a session with the active profile |
| `/resume` | Choose another session for this directory |
| `/fork [N]` | Branch before a user section or after an agent section |
| `/rewind [N]` | Truncate before a user section or after an agent section |
| `/compact [INSTRUCTIONS]` | Summarize older conversation into a child session, optionally steering the summary |
| `/compact_tools` | Clear older tool results into a child session without summarizing |
| `/copy [N]` | Copy the latest or selected conversation section |
| `/shell COMMAND` | Run a user-authored command and stage its output as context |
| `/skill NAME` | Load a skill as context for the next prompt |
| `/sandbox [TOOL [OP VALUE]]` | Inspect or update a tool's frozen sandbox policy |

See [Chat controls](CONFIG.md#chat) for client-owned commands, editor keys, and queued prompts, and [Conversation sections](CONFIG.md#conversation-sections) for stable command targets. Bundled submission hooks compact automatically near a known context-window limit and report Git identity changes.

Both compaction commands leave the source unchanged and open a child through the client. Startup context and the first user message are protected outside the recent-history allowance. They preserve recent turns' model-visible content in full, targeting 80 KiB of text and always keeping the latest turn. `/compact` summarizes the older conversation into the first user message, alongside the original user request preserved verbatim. Later compactions replace that summary rather than accumulating summaries. `/compact_tools` instead replaces older tool results, including images, with omission markers while preserving the conversation, tool calls, and exit status. Neither command creates a child when there is nothing to reduce. Automatic compaction preserves the interrupted prompt as an editable draft.

### Skills

Skills come from these sources in precedence order:

1. `.agents/skills/` in the working directory.
2. `skills/` in the selected Shellfish directory.
3. `.agents/skills/` beside that directory, only when it is named `.shellfish`.

With `~/.shellfish`, the last source is `~/.agents/skills/`. A project's `.shellfish` uses that project's `.agents/skills/` instead. There is no bundled skill fallback.

Set `"config": {"skills": ["skill-creator", "code-review"]}` to allow only those literal names. Omit `config.skills` to allow every discovered skill, or use `[]` to allow none. Missing names are ignored. The filter controls advertising, the `skill` tool, and `/skill`, not filesystem permissions.

A skill with `disable-model-invocation: true` is user-only. It is never advertised to the model or loaded by the `skill` tool, and loads only through `/skill`.

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

Without the choice lists, every subagent uses the parent's profile and model. Subagents cannot launch their own subagents. Commands are user actions, so subagents get none, and a task that looks like `/NAME` is an ordinary prompt. `max_active` is a positive integer, default `4`, limiting running subagents per parent. A subagent holds its slot only while its turn runs. Supplied settings freeze with the session.

Background work returns control after launch. Inspection distinguishes running work from a stopped subagent without a final outcome. Continuing a stopped subagent recovers unfinished work. A subagent killed during its stop hooks can appear settled, and those hooks do not run again.

### Stop review

Add `"stop/review"` to a profile's `hooks` to review each final answer against the user's intent before the turn finishes. It is not enabled by default. A rejection returns the reviewer's reason to the agent so it can continue. Failed or invalid reviews let the turn finish and display why. By default, at most two consecutive rejections are allowed per turn, then the next stop finishes without another review.

Settings live under `config.stop.review`. The reviewer inherits the session model unless you set `"model": "review"`. Alternatively, set `"decision_model": "d3"` to use a decision provider. Every question must pass, with each decision probability at least `allow_threshold` (default `0.8`). Set `max_rejections` to change the retry cap. Set `max_input_kb` to change the default 24 KB context budget. Startup context, the latest user message, and final assistant text stay pinned, with recent records fitted into the remaining budget and older tool output shortened. Set `http_timeout` in the review model to bound request duration.

The bundled [policy](../share/hooks/stop/review/policy.json) asks about fulfillment, reasonable execution, and scope. Replace the complete question list with `config.stop.review.questions`, an object mapping question names to `{"instructions": "A yes/no question"}` and optional `criteria` with `true` and `false` descriptions. Use positive questions: a true answer permits stopping. For example:

```json
{"hooks": ["stop/review"], "config": {"stop": {"review": {
  "decision_model": "d3", "allow_threshold": 0.8, "max_rejections": 2,
  "questions": {"complete": {"instructions": "Did the agent fulfill the user's request?"}}
}}}}
```

### Sandbox approver

Add `"sandbox/approver"` to a profile's `hooks` to have a model review sandbox access requests against the user's instructions. It approves or denies each request. Review failures fall back to asking the user.

The reviewer uses the session's model by default. Set `"config": {"sandbox": {"approver": {"model": "review"}}}` to select another model by name. The name freezes, but the model file is read on each review and replaces the complete model configuration, including the provider. Review requests impose their own structured output, output limit, and fixed input budget. The reviewer sees the system prompt, startup context, latest user message, and as much of the current turn as fits, with older tool output shortened. Set `"max_input_kb": 48` to raise the default 24 KB budget for larger or faster review models. Invalid settings, unavailable models, and provider failures leave the decision to the user. Set `http_timeout` in the review model's `config` to limit the duration of its request.

Set `decision_model` instead of `model` to use a [decision provider](MODELS.md#decisions), such as `{"decision_model": "d3"}`. It approves when authorization is at least 80% likely to cover the risk, and denies otherwise. Set `"allow_threshold": 0.5` to lower that bar. It also denies requests at least 50% likely to be driven by untrusted instructions. Denial reasons include these likelihoods. A refusal asks the user. Run `./tests/run decisions MODEL` to evaluate a model on sample requests.
