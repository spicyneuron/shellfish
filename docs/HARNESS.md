# Harnesses

A harness defines how Shellfish behaves as an agent. It combines tools, lifecycle hooks, sandbox policy, and turn limits around the shared execution loop. A profile selects a harness together with a backend, a system prompt, and model request settings.

The core owns the parts that must remain consistent: event ordering, persistence, recovery, and cleanup. The harness supplies the coding behavior and workflow policy. This separation lets a different harness turn the same runtime into a reviewer, research assistant, or project-specific agent without replacing the turn machinery.

Harnesses are resolved when a session is created and stored in its header. Changing a harness affects new sessions, not existing ones.

## Default coding harness

The bundled `default` harness is intentionally small. It provides project context, general-purpose tools, interactive commands, and conservative sandboxing. Its complete configuration lives in [`share/default/shellfish.jsonc`](../share/default/shellfish.jsonc).

### System prompt

The system prompt is a profile field, not a harness field. The bundled `default` profile lists two components:

- `general.md` defines communication and context-handling conventions.
- `tools.md` defines tool-use conventions.

These files live under `share/default/system/`; a user configuration can select different files or shadow bundled files by name. When a session is created, they are read in order, stripped of trailing newlines, and joined with a blank line into the session's single durable system record. The source paths are not stored in the session header. `--session-from PATH` copies the durable system record, so later file changes affect only sessions created from configuration.

For a new session, repeated `--system TEXT` and `--system-file PATH` inputs replace the configured or copied system prompt. Mixed inputs retain command-line order.

### Tools

- `read_file` reads project text files with line numbers.
- `edit_file` makes targeted replacements in existing project text files.
- `write_file` creates new project text files.
- `skill` loads instructions for an advertised Agent Skill.
- `search_web` uses Exa's anonymous MCP endpoint to search the web.
- `fetch_url` uses Jina Reader to fetch an HTTP(S) website as Markdown.
- `shell` runs one zsh command in the session working directory.

Tools are component directories with executable `run` files and JSON manifests. A manifest's optional `environment` array selects configuration values for that tool process. Tools otherwise start with a clean environment. The default harness enables sandboxing with [`fence`](https://github.com/fencesandbox/fence). Its policies constrain project and network access and deny common secret files. When a tool fails and sandbox monitoring reports a blocked action, the durable tool result records that fact for both the model and client presentation. Supported tool calls can request a one-time bypass in interactive clients. Headless execution denies requests that `permission_request` scripts do not decide.

Sandboxing applies to opted-in tools. Hook scripts and backend adapters are trusted executables and run with the user's permissions. See [Configuration](CONFIG.md#sandbox-grants) for persistent and one-off path grants.

### Session context

At the `session_start` hook, three scripts prepare context before the transcript is created:

- `project_environment` reports the host, project tree, available shell commands, and Agent Skills.
- `git_environment` reports Git context at startup and branch or detached-commit changes before later prompts.
- `project_instructions` loads the project's `AGENTS.md`, or `CLAUDE.md` when `AGENTS.md` is absent.

This context becomes part of the durable initial session prefix. It is collected once for a new session rather than before every turn.

The filesystem listing in `project_environment` and each Git probe use a one-second wall-clock budget so session startup stays fast. A slow filesystem skips the listing but retains the other environment context; a slow Git probe reports no context. Set `SHELLFISH_PROBE_BUDGET` to a positive number of seconds to raise the limit on a slow host; other values are ignored.

Skills are discovered in descending precedence from `./.agents/skills/`, the resolved configuration directory's `skills/`, `~/.agents/skills/`, and bundled `share/default/skills/`. Each skill directory contains a `SKILL.md` whose frontmatter supplies its matching `name` and `description`. Invalid skills and skills with `disable-model-invocation: true` are unavailable to the model. The advertised catalog is recorded when the session is created; the `skill` tool reads the selected file when invoked.

### Interactive commands

Most chat commands are bundled scripts on the `user_prompt_submit` hook:

| Command | Description |
| --- | --- |
| `/help`, `/h` | List available commands and editor keys. |
| `/new` | Create a new session with the active session's settings. |
| `/copy [N]` | Copy the text of the latest user/agent section, or section `N`, to the local clipboard. |
| `/fork [N]` | Copy the transcript into a new session at section `N`, resolving an agent section to the following user section and restoring that prompt as an editable draft. Without an index it forks at the current end. |
| `/compact` | Summarize the conversation into a child session and request a handoff to it. See [Compaction](#compaction). |
| `/refresh`, `/r` | Rebuild the terminal presentation from the durable session. Fixes layout corruption. |
| `/verbose`, `/v` | Toggle presentation preview limits. |
| `/sandbox [OP DIR]` | List the session's sandbox path grants, or update them in place. |
| `/resume` | Switch to another session in the same project. |
| `/server` | Hand the current session to the optional `shellfish-server` process. |
| `! command` | Run a shell command and inject its input and output as context. |

The commands that replace the current session — `/new`, `/fork`, `/compact`, `/refresh`, `/verbose`, `/resume`, and `/server` — do not switch in place. They request a [handoff](HOOKS.md#user_prompt_submit): chat exits and relaunches Shellfish, usually with a new session path.

`/sandbox read DIR` and `/sandbox write DIR` add a grant, `-read` and `-write` remove one; `+` is accepted when adding, and signed forms may abbreviate the operation to `r` or `w`. Additions must name an existing directory. Paths beginning with `~/` use `HOME`, relative paths use the session working directory, and stored additions are canonical absolute paths. Read and write lists remain independent, and removing an exact child grant does not restrict access inherited from a granted parent. After an update, the client refreshes its runtime without replaying the transcript.

These features are harness behavior, not special cases in the agent loop. A custom harness can omit them, replace them, or bind other scripts to the same hook.

### Compaction

Compaction is a `user_prompt_submit` script that replaces a full conversation with a summary in a child session. It composes `shellfish build-request` and `shellfish send-request` with tools disabled, so the summary request runs no hooks and executes no tools.

`/compact` summarizes on demand. Automatic compaction runs when the most recent measured assistant usage reaches 80% of the frozen `context_window`; an unavailable window disables the automatic threshold.

Compaction creates a sibling child named with a `_compact` suffix without changing the source. The child copies everything before the first user message, the session header, system record, and all committed context, then replaces the conversation with one summary context. A successful script requests a client handoff to the child. Automatic compaction passes the interrupted prompt as an editable draft rather than submitting it. Automatic failures are fail-open and submit the prompt to the source; explicit `/compact` failures stop that command and leave the source active.

### Limits

The bundled harness allows up to 100 provider requests per turn and 25 tool calls per provider response. Tool output is truncated to 32 KiB. Each hook script invocation has a separate 32 KiB budget across stdout, stderr, and fd 3; exceeding it fails the operation. These limits bound accidental loops and oversized context while leaving room for multi-step coding tasks.

## Build a focused harness

A harness can be smaller than the default. For example, a review harness might expose only `read_file`, retain the project context scripts, and keep sandboxing enabled, with a review-specific system prompt set on the profile that selects it. Harnesses do not inherit from one another, so each named harness lists the capabilities it needs.

The configuration template includes a `readonly` harness with the `read_file` and `shell_readonly` tools, selected by a `readonly` profile that uses the bundled `readonly.md` system component.

See [Customize a harness](CONFIG.md#customize-a-harness) for a configuration example, component lookup rules, and sandbox grants. See [Hooks](HOOKS.md) for lifecycle payloads, control decisions, and environment guarantees.
