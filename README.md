```
╭─╮╷ ╷╭─╴╷  ╷  ╭─╴╷╭─╮╷ ╷   ╭───────
╰─╮├─┤├╴ │  │  ├╴ │╰─╮├─┤   ╰𝆒 ◕ )]]]]]╮
╰─╯╵ ╵╰─╴╰─╴╰─╴╵  ╵╰─╯╵ ╵      <<<<<   ⨇
```

A tiny coding agent written in a few thousand lines of `zsh`, `awk`, `curl`, and `jq`.

Absurdly extensible (shell scripts!) with a familiar Claude Code and Codex TUI (distillation attack!), yet none of the bloat, telemetry, or supply chain surface area.

Under-the-hood, an AI agent is just a state machine, an append-only log, an HTTP client, and some tools. It should not need 1000+ npm dependencies, half a million lines of code, or, God-forbid, an Electron app.

This entire codebase fits comfortably within the context window of any modern LLM. It's small enough to run anywhere, and flexible enough to mold into any shape you need.

## Core promise

- Your **harness** is just markdown and shell scripts, bound to lifecycle hooks.
- Your **tools** are just shell scripts, optionally sandboxed with [`fence`](https://github.com/fencesandbox/fence).
- Your **backend** is just a shell script that `curl`s out to APIs and returns JSON. Built-in support for OpenAI, Codex (ChatGPT subscription), Anthropic, OpenRouter, llama.cpp.

## Default harness

### Tools
- `read_file`, `edit_file`, `write_file` for simple text operations.
- `shell` to run arbitrary commands within a `fence` sandbox.

### `session_start` hook
- `add_environment` to inject host, project tree, and Git context.
- `add_command_availability` to report available shell command versions.
- `add_project_instructions` to inject the project's `AGENTS.md` or, if absent, `CLAUDE.md`.

### `user_prompt_submit` hook
- `/new` to create a new session in the same project.
- `/fork [N]` to copy and trim the current transcript into a new session.
- `/refresh` to rebuild the terminal presentation from the durable session.
- `/server` to hand the current session to `shellfish-server`.
- `! command` to run a shell command and inject its input and output as context.

Custom harnesses can attach additional policy or context scripts to any lifecycle event described in [`docs/HOOKS.md`](docs/HOOKS.md).

## Install

Shellfish requires `zsh` 5+, `awk`, `curl`, and [`jq`](https://github.com/jqlang/jq). The default harness needs [`fence`](https://github.com/fencesandbox/fence) to run sandboxed tools. Set `sandbox: false` on a harness only when those tools should run unsandboxed with full user permissions.

```sh
# Ensure that ~/.local/bin is on your $PATH. Then:
mkdir -p "$HOME/.local/share" "$HOME/.local/bin"
git clone https://github.com/spicyneuron/shellfish.git "$HOME/.local/share/shellfish"
ln -s "$HOME/.local/share/shellfish/bin/shellfish" "$HOME/.local/bin/shellfish"
```

## Quick start

Shellfish has three modes:

- `shellfish` opens the interactive terminal agent.
- `shellfish exec` runs exactly one turn and prints the results.
- `shellfish-server` runs a tiny, web-based terminal agent accessible at `127.0.0.1:9158`.

```sh
# Provide keys via environment or ${XDG_CONFIG_HOME:-$HOME/.config}/shellfish/.env
export OPENROUTER_API_KEY=...

# Start a chat
shellfish --backend openrouter --model MODEL

# Use your Codex subscription
shellfish --backend codex --model MODEL

# Continue a previous session
shellfish --session path/to/session.jsonl

# Run a single prompt and print final assistant message
shellfish exec -b openrouter -m MODEL "Explain this project"
echo "Review the current changes" | shellfish exec -b openrouter -m MODEL
```

Built-in credentials:

| Backend | Credential |
| --- | --- |
| `anthropic` | `ANTHROPIC_API_KEY` |
| `codex` | Existing Codex CLI login |
| `openai` | `OPENAI_API_KEY` |
| `openai-responses` | `OPENAI_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |

The `openai` backend also supports compatible services by setting `endpoint` in its backend config.

## Documentation

- [`docs/CONFIG.md`](docs/CONFIG.md) — configure profiles, backends, harnesses, components, and sandbox grants.
- [`docs/EXEC.md`](docs/EXEC.md) — integrate with the bounded-exec JSONL interface.
- [`docs/HOOKS.md`](docs/HOOKS.md) — write lifecycle hooks.
- [`docs/SERVER.md`](docs/SERVER.md) — run or integrate with the browser server.
- [`docs/CHAT.md`](docs/CHAT.md) — understand the interactive chat architecture.

## Configure

Shellfish is built around backends, harnesses, and profiles.

- Backends select an API adapter and its transport settings.
- Harnesses select system files, tools, hooks, sandbox policy, and turn limits.
- Profiles compose a backend, a harness, and API request settings such as the model.
- Top-level theme and `tui` settings control presentation independently of profiles.

Shellfish recursively merges user configuration over the bundled `default/config.jsonc`; arrays replace rather than extend their defaults. Component references resolve from the configuration directory before bundled defaults. Create `$XDG_CONFIG_HOME/shellfish/` (`~/.config/shellfish/` by default), and use `shellfish config` to inspect the resolved result. See `config.template.jsonc` for a starting point, `default/config.jsonc` for annotated defaults, and `config.schema.json` for all accepted fields.

## Sessions

Sessions are append-only JSONL transcripts stored beneath `${XDG_STATE_HOME:-$HOME/.local/state}/shellfish/sessions`. A session retains its resolved backend, harness, model, request, and sandbox settings; create a new session to change them. Themes and TUI preview settings come from the current configuration, so they can change how an existing session is displayed.

Use `--continue` to open the newest session for the current directory, `--resume` to pick one interactively, or `--session PATH` to name one directly. `shellfish exec --new` creates an idle session and prints its path without running a turn.

See [`docs/EXEC.md`](docs/EXEC.md) for the bounded-exec JSONL interface used by chat and the server.

## Safety

Built-in `shell`, `read_file`, `edit_file`, and `write_file` tools run in `fence` by default. Their policies limit project access, block network access, and deny common secret files. Additional paths configured with `sandbox_read_paths` and `sandbox_write_paths` retain the tool's other restrictions. An interactive tool may request a one-time bypass when allowed by its manifest; headless runs deny requests that policy hooks do not decide.

Hooks, backend adapters, and unsandboxed tools are trusted executables and run with the user's permissions. Disabling harness sandboxing removes the tool boundary; it does not provide an alternative isolation mechanism.

## Server (experimental)

To install the optional server binary (requires Go):

```sh
go install github.com/spicyneuron/shellfish/server@latest
```

## Develop

```sh
./tests/run unit     # shell unit tests
./tests/run pty      # terminal integration tests
./tests/run metrics  # performance and source size reports
./tests/run unit/session/main.zsh unit/runtime/main.zsh
```

Tests use fake provider responses and do not require network access.
