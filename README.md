```
╭─╮╷ ╷╭─╴╷  ╷  ╭─╴╷╭─╮╷ ╷   ╭───────
╰─╮├─┤├╴ │  │  ├╴ │╰─╮├─┤   ╰𝆒 ◕ )]]]]]╮
╰─╯╵ ╵╰─╴╰─╴╰─╴╵  ╵╰─╯╵ ╵      <<<<<   ⨇
```

A tiny coding agent written in a few thousand lines of `zsh`, `awk`, `curl`, and `jq`.

Absurdly extensible (shell scripts!), familiar Claude Code and Codex TUI (distillation attack!), yet none of the bloat, telemetry, or supply chain surface area.

Under-the-hood, an AI agent is just a state machine, an append-only log, an HTTP client, and some tools. It should not need 1000+ npm dependencies, a half-million lines of Rust, or, God-forbid, another Electron app.

This entire codebase fits comfortably within the context window of any modern LLM. It's small enough to run anywhere, and flexible enough to mold into any shape you need.

## Core Promise

- Your **harness** is just markdown and shell scripts, bound to lifecycle hooks.
- Your **tools** are just shell scripts, optionally sandboxed with [`fence`](https://github.com/fencesandbox/fence).
- Your **backend** is just a shell script that `curl`s out to APIs and returns JSON. Built-in support for OpenAI, Codex (ChatGPT subscription), Anthropic, OpenRouter, llama.cpp...

## Example harness scripts

### tools
- `read_file`, `edit_file`, `write_file` for simple text operations.
- `shell` to run arbitrary commands within a `fence` sandbox.

### session_start
- `add_project_environment` to inject context about the host system, `git` status, and available commands and versions.
- `add_project_instructions` to `cat` AGENTS.md or CLAUDE.md into context.

### user_prompt_submit
- `/new` to exit and rerun `shellfish`, creating a new session in the same project.
- `/fork [N]` to copy the current session's JSONL transcript, trim it with `jq`, and rerun with `shellfish --session`.
- `/resume` to exit and run a separate TUI to select and load another session.
- `! command` to run arbitrary shell commands and inject stdin and stdout as context.

## post_tool_use
- `mark_changed` to detect when files have been changed and create a sentinel file if so.

## stop
- `remind_changes` to detect the `mark_changed` sentinel file and force the agent to recheck its work before completing.
- `notify` to show a UI notification.

## Install

Shellfish requires `zsh` 5+, `awk`, `curl`, and [`jq`](https://github.com/jqlang/jq). [`fence`](https://github.com/fencesandbox/fence) is a soft requirement tool sandboxing, but can be disabled.

```sh
# Ensure that ~/.local/bin is on your $PATH. Then:
mkdir -p "$HOME/.local/share" "$HOME/.local/bin"
git clone https://github.com/spicyneuron/shellfish.git "$HOME/.local/share/shellfish"
ln -s "$HOME/.local/share/shellfish/bin/shellfish" "$HOME/.local/bin/shellfish"
```

## Quick start

```sh
# Provide keys via environment or $XDG_CONFIG/shellfish/.env
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

Shellfish has three modes:

- `shellfish` opens the interactive terminal agent.
- `shellfish exec` runs exactly one turn and prints the results.
- `shellfish-server` runs a tiny, web-based terminal agent accessible at `127.0.0.1:9158`.

Built-in credentials:

| Backend | Credential |
| --- | --- |
| `anthropic` | `ANTHROPIC_API_KEY` |
| `codex` | Existing Codex CLI login |
| `openai` | `OPENAI_API_KEY` |
| `openai-responses` | `OPENAI_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |

The `openai` backend also supports compatible services by setting `endpoint` in its backend config.

## Configure

Shellfish is built around backends, harnesses, and profiles.

- Backends are API adapters that build requests and return JSON.
- Harnesses are collections of shell scripts attached to lifecycle hooks.
- Profiles are shortcuts that configure a backend, a harness, a model, and API request settings.

Configure these by creating `$XDG_CONFIG_HOME/shellfish/` (`~/.config/shellfish/` by default).

`./.env`

`./config.jsonc`

`./backends/`

`./system/`

`./tools/`

`./hooks/`

## Sessions

TODO

## Safety

Built-in `shell`, `read_file`, `edit_file`, and `write_file` tools run in `fence` by default. Their policies limit project access, block network access, and deny common secret files.

Additional paths configured with `sandbox_read_paths` and `sandbox_write_paths` retain the tool's other sandbox restrictions. An interactive tool may request a one-time bypass when allowed by its manifest.

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
