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

These files live under `share/default/system/`; a user configuration can select different files or shadow bundled files by name. They are read in order, stripped of trailing newlines, and joined with a blank line into the session's single durable system record. Resolved paths are stored in the session header, and creating a new session from an existing one rematerializes those frozen paths.

### Tools

- `read_file` reads project text files with line numbers.
- `edit_file` makes targeted replacements in existing project text files.
- `write_file` creates new project text files.
- `skill` loads instructions for an advertised Agent Skill.
- `search_web` uses Exa's anonymous MCP endpoint to search the web.
- `fetch_url` uses Jina Reader to fetch an HTTP(S) website as Markdown.
- `shell` runs one Zsh command in the session working directory.

Tools are shell scripts with JSON manifests. The default harness enables sandboxing with [`fence`](https://github.com/fencesandbox/fence). Its policies constrain project and network access and deny common secret files. When a tool fails and sandbox monitoring reports a blocked action, the durable tool result records that fact for both the model and client presentation. Supported tool calls can request a one-time bypass in interactive clients; headless execution denies requests that `permission_request` scripts do not decide.

Sandboxing applies to opted-in tools. Hook scripts and backend adapters are trusted executables and run with the user's permissions. See [Configuration](CONFIG.md#sandbox-grants) for persistent and one-off path grants.

### Session context

At the `session_start` hook, five scripts prepare context before the transcript is created:

- `project_environment` reports the host and project tree.
- `git_awareness` reports Git context at startup and branch or detached-commit changes before later prompts.
- `shell_commands` reports versions of common shell commands when available.
- `project_instructions` loads the project's `AGENTS.md`, or `CLAUDE.md` when `AGENTS.md` is absent.
- `skills` advertises available Agent Skills.

This context becomes part of the durable initial session prefix. It is collected once for a new session rather than before every turn.

The `project_environment` and `git_awareness` probes share a one-second wall-clock budget so session startup stays fast, and report no context when a host exceeds it. Set `SHELLFISH_PROBE_BUDGET` to a positive number of seconds to raise it on a slow host; other values are ignored.

Skills are discovered in descending precedence from `./.agents/skills/`, the resolved configuration directory's `skills/`, `~/.agents/skills/`, and bundled `share/default/skills/`. Each skill directory contains a `SKILL.md` whose frontmatter supplies its matching `name` and `description`. Invalid skills and skills with `disable-model-invocation: true` are unavailable to the model. The advertised catalog is recorded when the session is created; the `skill` tool reads the selected file when invoked.

### Interactive commands

The default harness implements most chat commands as scripts on the `user_prompt_submit` hook:

- `/help` lists available commands.
- `/new` creates a new session with the active session's settings.
- `/copy [N]` copies the text of the latest user/agent section, or section `N`, to the local clipboard.
- `/fork [N]` copies the transcript into a new session at section `N`, resolving an agent section to the following user section and restoring that prompt as an editable draft. Without an index it forks at the current end.
- `/compact` summarizes the conversation into a child session and requests a handoff to it.
- `/refresh` rebuilds the terminal presentation from the durable session.
- `/verbose` toggles presentation preview limits.
- `/sandbox` lists or updates the session's sandbox path grants.
- `/resume` switches to another session in the same project.
- `/server` hands the current session to the optional `shellfish-server` process.
- `! command` runs a shell command and injects its input and output as context.

These features are harness behavior, not special cases in the agent loop. A custom harness can omit them, replace them, or bind other scripts to the same hook.

### Limits

The bundled harness allows up to 100 provider requests per turn and 25 tool calls per provider response. Tool output is truncated to 32 KiB. Each hook script invocation has a separate 32 KiB budget across stdout, stderr, and fd 3; exceeding it fails the operation. These limits bound accidental loops and oversized context while leaving room for multi-step coding tasks.

## Build a focused harness

A harness can be smaller than the default. For example, a review harness might expose only `read_file`, retain the project context scripts, and keep sandboxing enabled, with a review-specific system prompt set on the profile that selects it. Harnesses do not inherit from one another, so each named harness lists the capabilities it needs.

The configuration template includes a `readonly` harness with the `read_file` and `shell_readonly` tools, selected by a `readonly` profile that uses the bundled `readonly.md` system component.

See [Customize a harness](CONFIG.md#customize-a-harness) for a configuration example, component lookup rules, and sandbox grants. See [Hooks](HOOKS.md) for lifecycle payloads, control decisions, and environment guarantees.
