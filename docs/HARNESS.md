# Harnesses

A harness defines how Shellfish behaves as an agent. It combines tools, lifecycle hooks, sandbox policy, and turn limits around the shared execution loop. A profile selects a harness together with a backend, a system prompt, and model request settings.

The core owns event ordering, persistence, recovery, and cleanup. The harness supplies tools and workflow policy. Harnesses are frozen when a session is created, so changes affect new sessions rather than existing ones.

## Default coding harness

The bundled `default` harness provides project context, general-purpose coding tools, interactive commands, compaction, and conservative sandboxing. Its configuration and components under [`share/default/`](../share/default/) are the authoritative reference.

### System prompt

The system prompt belongs to the profile rather than the harness, so the same harness can support different roles. Shellfish materializes the selected system components when it creates a session. Later file changes do not alter that session's prompt.

| Component | Role |
| --- | --- |
| `general.md` | Communication, execution, and context-handling guidance |
| `tools.md` | Conventions for using the bundled tools |

### Tools

Tools are executable components with model-facing JSON schemas. The default tools cover file access, shell commands, web access, and Agent Skills.

| Component | Role |
| --- | --- |
| `read_file` | Read project text with line numbers |
| `edit_file` | Make targeted replacements in existing text files |
| `write_file` | Create text files |
| `skill` | Load an advertised Agent Skill |
| `search_web` | Search the web |
| `fetch_url` | Fetch a web page as Markdown |
| `shell` | Run a zsh command in the session working directory |

Tools start with a restricted environment and may run inside the configured [`fence`](https://github.com/fencesandbox/fence) sandbox. Interactive clients can ask the user to approve a supported one-time bypass. Hook scripts and backend adapters remain trusted and unsandboxed. See [Tools](TOOLS.md) for the component contract and [Sandbox grants](CONFIG.md#sandbox-grants) for persistent access.

### Session context

At session creation, startup hooks add project, Git, instruction, and available-skill context. This context is recorded once rather than rediscovered before every turn.

| Component | Role |
| --- | --- |
| `project_environment` | Host, project tree, available commands, and skills |
| `git_environment` | Repository and branch context |
| `project_instructions` | Project `AGENTS.md`, falling back to `CLAUDE.md` |

### Interactive commands

Most slash commands are `user_prompt_submit` hooks supplied by the harness. They provide help, session creation and derivation, sandbox updates, shell context, presentation changes, and server handoff. Run `/help` for the current command set.

| Component | Role |
| --- | --- |
| `help` | Show available commands and editor keys |
| `verbose` | Toggle full presentation previews |
| `new` | Start a session with the active runtime |
| `copy` | Copy a conversation section to the clipboard |
| `fork` | Derive a session from a transcript prefix |
| `sandbox` | Inspect or update session sandbox grants |
| `user_shell` | Run `!` commands and add their output as context |
| `server` | Hand the session to `shellfish-server` |
| `resume` | Choose another project session |
| `compact` | Summarize the conversation into a child session |
| `git_environment` | Add context when Git identity changes |

Commands that replace the active session request a [handoff](HOOKS.md#user_prompt_submit) for the client to perform. Client lifecycle commands such as `/refresh` and `/quit` are not hooks. A custom harness can omit or replace the bundled commands without changing the agent loop.

### Permission review

The bundled `review` component can decide sandbox bypass requests without interactive approval. It uses one inference to classify risk and user authorization, then allows only when authorization is at least as high as risk. Failures deny the request. Classifications and reasons remain in model-hidden state; a denial reason is also shown as tool feedback.

Review is disabled by default. Enable it with `"permission_request": ["review"]`. It uses the session's inference settings unless `SHELLFISH_PERMISSION_PROFILE` selects another profile in `.env`.

### Compaction

Once a session has completed its first turn, `/compact` can summarize it into a child session without changing the source. The summary carries unfinished work and current status within its chronology. The default harness can also compact automatically as the conversation approaches a known context-window limit.

Successful compaction asks the client to open the child. Automatic compaction preserves the interrupted prompt as an editable draft. Harnesses bound provider requests per turn, tool calls per response, and captured component output.

## Build a focused harness

A focused harness exposes only the tools and hooks its role requires. Harnesses do not inherit, and the profile that selects one supplies its system prompt and backend settings.

See [Customize a harness](CONFIG.md#customize-a-harness) for configuration and component lookup, and [Hooks](HOOKS.md) for the lifecycle contract.
