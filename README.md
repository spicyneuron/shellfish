> [!NOTE]
> This project is early days, and things may be a bit crabby. Stay tuned!

```
╭─╮╷ ╷╭─╴╷  ╷  ╭─╴╷╭─╮╷ ╷   ╭───────
╰─╮├─┤├╴ │  │  ├╴ │╰─╮├─┤   ╰𝆒 ◕ )]]]]]╮
╰─╯╵ ╵╰─╴╰─╴╰─╴╵  ╵╰─╯╵ ╵      <<<<<   ⨇
```

A tiny coding agent written in a few thousand lines of `zsh`, `awk`, `curl`, and `jq`.

Absurdly extensible (shell scripts!) with a familiar Claude Code and Codex TUI (distillation attack!). No bloat, telemetry, or sprawling supply chain surface area.

Under-the-hood, an AI agent is just a state machine, an append-only log, an HTTP client, and some tools. It should not need 1000+ npm dependencies, half a million lines of code, or, God-forbid, an Electron app.

This entire codebase fits comfortably within the context window of any modern LLM. It's small enough to run anywhere and flexible enough to adapt to any workflow.

## Core promise

- Your **harness** is just markdown and shell scripts, bound to lifecycle hooks.
- Your **tools** are just shell scripts, optionally sandboxed with [`fence`](https://github.com/fencesandbox/fence).
- Your **backend** is just a shell script that `curl`s out to APIs and returns JSON. Built-in support for OpenAI, Codex (ChatGPT subscription), Anthropic, OpenRouter, llama.cpp.

## Highlights

- **Context is just stdout.** Hook scripts turn ordinary command output into model context, making it easy to extend awareness of project state and changes.
- **Extensible agent loop.** Hook scripts run in a pipeline, gating actions, modifying state, and even launching other services.
- **Audit in one sitting.** Agent behavior is inspectable Markdown, shell, and JSON; full session state is just JSONL.
- **Harnesses, plural.** Configure multiple purpose-built agents instead of forcing every workflow into one configuration.
- **Take a session on the go.** The optional server exposes your agent through a lightweight browser client. Because what could go wrong?

The bundled harness is a minimal starting point. The [default harness guide](docs/HARNESS.md) explains how its pieces fit together.

## Get started

Shellfish requires `zsh` 5+, `awk`, `curl`, and [`jq`](https://github.com/jqlang/jq). The default harness needs [`fence`](https://github.com/fencesandbox/fence) for sandboxed tools.

Install via git:

```sh
# With `~/.local/bin` on `PATH`
mkdir -p "$HOME/.local/share" "$HOME/.local/bin"
git clone https://github.com/spicyneuron/shellfish.git "$HOME/.local/share/shellfish"
ln -s "$HOME/.local/share/shellfish/bin/shellfish" "$HOME/.local/bin/shellfish"
```

Provide credentials through the environment or `${XDG_CONFIG_HOME:-$HOME/.config}/shellfish/.env`, then start an interactive chat:

```sh
export OPENROUTER_API_KEY=...
shellfish --backend openrouter --model MODEL
```

Or use your existing Codex subscription login:

```sh
shellfish --backend codex --model MODEL
```

Built-in backends and credentials:

| Backend | Credential |
| --- | --- |
| `anthropic` | `ANTHROPIC_API_KEY` |
| `codex` | Existing Codex CLI login |
| `openai` | `OPENAI_API_KEY` |
| `openai-responses` | `OPENAI_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |

The `openai` backend also supports compatible services by setting `endpoint` in its backend config.

## Documentation

- [`docs/CONFIG.md`](docs/CONFIG.md): Configure profiles, backends, harnesses, components, and sandbox grants.
- [`docs/HARNESS.md`](docs/HARNESS.md): Understand the harness role and the bundled defaults.
- [`docs/CHAT.md`](docs/CHAT.md): Use interactive chat, slash commands, and keybindings.
- [`docs/HOOKS.md`](docs/HOOKS.md): Write custom lifecycle hooks.
- [`docs/BACKENDS.md`](docs/BACKENDS.md): Write provider backend adapters.
- [`docs/EXEC.md`](docs/EXEC.md): Integrate with the single-turn JSONL interface.
- [`docs/SERVER.md`](docs/SERVER.md): Serve a session for remote access.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): Design intent and opinionated boundaries.
- [`docs/CURSED.md`](docs/CURSED.md): Hard-won lessons and ~~hacks~~ clever workarounds.

## Server (experimental)

`shellfish-server` accepts the same flags as `shellfish` and serves a web client at `127.0.0.1:9158`.

Configure a VPN like Tailscale or Wireguard, and then control `shellfish` from your phone! For now, only one session at a time.

```sh
# Install
go install github.com/spicyneuron/shellfish/shellfish-server@latest

# Serve a project with default profile
cd my/project/
shellfish-server
```

## Develop

```sh
./tests/run unit     # shell unit tests
./tests/run pty      # terminal integration tests
./tests/run server   # browser and Go server tests
./tests/run metrics  # performance and source size reports
./tests/run unit/session/main.zsh unit/runtime/main.zsh
```
