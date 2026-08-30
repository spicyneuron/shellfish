# Harnesses

A harness defines how Shellfish behaves as an agent. It combines system prompts, tools, lifecycle hooks, sandbox policy, and turn limits around the shared execution loop. A profile selects a harness together with a backend and model request settings.

The core owns the parts that must remain consistent: event ordering, session locking, persistence, recovery, and cleanup. The harness supplies the coding behavior and workflow policy. This separation lets a different harness turn the same runtime into a reviewer, research assistant, or project-specific agent without replacing the turn machinery.

Harnesses are resolved when a session is created and stored in its header. Changing a harness affects new sessions, not existing ones.

## Default coding harness

The bundled `default` harness is intentionally small. It provides project context, four general-purpose tools, interactive commands, sandboxing, and conservative turn limits. Its complete configuration lives in [`default/shellfish.jsonc`](../default/shellfish.jsonc).

### System prompt

The harness builds its system prompt from two Markdown files:

- `general.md` defines communication and context-handling conventions.
- `tools.md` directs the agent to prefer native file tools over shell commands.

These are ordinary component files under `default/system/`; a user configuration can select different files or shadow bundled files by name.

### Tools

- `read_file` reads project text files with line numbers.
- `edit_file` makes targeted replacements in existing project text files.
- `write_file` creates new project text files.
- `shell` runs one Zsh command in the session working directory.

Tools are shell scripts with JSON manifests. The default harness enables sandboxing with [`fence`](https://github.com/fencesandbox/fence). Its policies constrain project access, block network access, and deny common secret files. Supported tool calls can request a one-time bypass in interactive clients; headless execution denies requests that hooks do not decide.

Sandboxing applies to opted-in tools. Hooks and backend adapters are trusted executables and run with the user's permissions. See [Configuration](CONFIG.md#sandbox-grants) for persistent and one-off path grants.

### Project context

At session start, three hooks prepare context before the transcript is created:

- `add_environment` reports the host, project tree, and Git context.
- `add_command_availability` reports versions of common shell commands when available.
- `add_project_instructions` loads the project's `AGENTS.md`, or `CLAUDE.md` when `AGENTS.md` is absent.

This context becomes part of the durable initial session prefix. It is collected once for a new session rather than before every turn.

### Interactive commands

The default harness implements most chat commands as `user_prompt_submit` hooks:

- `/help` lists available commands.
- `/new` creates a new session with the active session's settings.
- `/fork [N]` copies the transcript into a new session, excluding the last `N` user turns when specified.
- `/refresh` rebuilds the terminal presentation from the durable session.
- `/verbose` toggles presentation preview limits.
- `/resume` switches to another session in the same project.
- `/server` hands the current session to the optional `shellfish-server` process.
- `! command` runs a shell command and injects its input and output as context.

These features are harness behavior, not special cases in the agent loop. A custom harness can omit them, replace them, or bind other scripts to the same lifecycle event.

### Limits

The bundled harness allows up to 50 provider requests per turn and 20 tool calls per provider response. Tool output is truncated to 32 KiB. Each hook invocation has a separate 32 KiB budget across stdout, stderr, and fd 3; exceeding it fails the operation. These limits bound accidental loops and oversized context while leaving room for multi-step coding tasks.

## Build a focused harness

A harness can be smaller than the default. For example, a review harness might use a review-specific system prompt, expose only `read_file`, retain project context hooks, and keep sandboxing enabled. Harnesses do not inherit from one another, so each named harness lists the capabilities it needs.

See [Customize a harness](CONFIG.md#customize-a-harness) for a configuration example, component lookup rules, and sandbox grants. See [Hooks](HOOKS.md) for lifecycle payloads, control decisions, and environment guarantees.
