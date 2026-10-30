> [!NOTE]
> This project is early days, and things may be a bit crabby. Stay tuned!

```
╭─╮╷ ╷╭─╴╷  ╷  ╭─╴╷╭─╮╷ ╷   ╭───────
╰─╮├─┤├╴ │  │  ├╴ │╰─╮├─┤   ╰𝆒 ◕ )]]]]]╮
╰─╯╵ ╵╰─╴╰─╴╰─╴╵  ╵╰─╯╵ ╵      <<<<<   ⨇
```

A tiny coding agent written in a few thousand lines of `zsh`, `awk`, `curl`, and `jq`.

Absurdly extensible (shell scripts!) with a familiar Claude Code and Codex TUI (distillation attack!). No bloat, telemetry, or sprawling supply chain surface area.

Under the hood, an AI agent is just a state machine, an append-only log, an HTTP client, and some tools. It should not need 1000+ npm dependencies, half a million lines of code, or, God forbid, an Electron app.

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

## Installation

Shellfish requires `zsh` 5+, `awk`, `curl`, and [`jq`](https://github.com/jqlang/jq). On Linux it also requires `setsid`. On macOS it uses the system `script` utility for process-group creation. The default harness needs [`fence`](https://github.com/fencesandbox/fence) for sandboxed tools.

```sh
# With `~/.local/bin` on `PATH`
mkdir -p "$HOME/.local/share" "$HOME/.local/bin"
git clone https://github.com/spicyneuron/shellfish.git "$HOME/.local/share/shellfish"
ln -s "$HOME/.local/share/shellfish/bin/shellfish" "$HOME/.local/bin/shellfish"
```

## Getting started

```sh
shellfish init                    # Write starter config into ~/.shellfish
# Name a model in ~/.shellfish/models/default.jsonc and its key in ~/.shellfish/.env

shellfish                         # Start a new session
shellfish --continue              # Reopen the most recent session
shellfish --resume                # Pick a session from this directory
shellfish --session PATH          # Open one session directly

shellfish --model MODEL           # Use models/MODEL.jsonc instead of the default
shellfish --profile PROFILE       # Use another profile, such as basic, readonly, or plus
shellfish -m '{"adapter": "openrouter", "request": {"model": "MODEL"}}' -t shell
                                  # Select everything with options, no config needed

shellfish run "PROMPT"            # Run one non-interactive turn
```

Built-in backends and credentials:

| Backend | Credential |
| --- | --- |
| `anthropic` | `ANTHROPIC_API_KEY` |
| `codex` | Existing Codex CLI login |
| `openai` | `OPENAI_API_KEY` |
| `openai_responses` | `OPENAI_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |

The `openai` adapter also supports compatible services by setting `endpoint` in a model file.

Run `shellfish --help` for creation and sandbox options, or `/help` inside chat for commands supplied by the active harness.

## Configuration

The Shellfish directory (typically `~/.shellfish/`, see [Directories](docs/CONFIG.md#directories)) holds three kinds of configuration:

- **Profiles** in `profiles/` select an agent's parts: sandbox files, system prompts, tools, commands, and hooks.
- **Models** in `models/` configure the request: adapter, endpoint, and provider parameters. A model is chosen separately from the profile, and repeated `-m` options merge left to right.
- **Sandbox files** in `sandbox/` enable sandboxing and grant extra paths.
- **Settings** in `.env` or the environment hold credentials and limits.

```jsonc
// ~/.shellfish/profiles/review.jsonc — shellfish -p review
{
  "$schema": "https://raw.githubusercontent.com/spicyneuron/shellfish/refs/heads/main/share/profile.schema.json",
  "sandbox": "default",
  "system": ["general.md", "review.md"],  // ~/.shellfish/system/review.md
  "tools": ["read_file", "shell_readonly"],
  "hooks": ["project/instructions"]
}
```

`profiles/default.jsonc` is selected when `--profile` is absent, and `models/default.jsonc` when `--model` is. Reusable components live in top-level `system/`, `tools/`, `commands/`, `hooks/`, and `backends/` directories beside `profiles/`, and resolve from the Shellfish directory first, then the bundled `share/` directory. A reference starting with `/`, `~/`, `./`, `../`, or `@` is a path instead, where `@` is the bundled root. Every profile field also has a command-line option. A new session freezes the resolved profile and model in its header. Themes and preview limits live in [`tui.jsonc`](share/tui.jsonc).

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): Design intent and opinionated boundaries.
- [`docs/CONFIG.md`](docs/CONFIG.md): Configure profiles, models, settings, presentation, and the starter agent.
- [`docs/HARNESS.md`](docs/HARNESS.md): Write custom commands, hooks, tools, and backend adapters.
- [`docs/CURSED.md`](docs/CURSED.md): Hard-won lessons and ~~hacks~~ clever workarounds.

## Develop

```sh
./tests/run          # shell tests
./tests/run pty      # terminal integration tests
./tests/run server   # browser and Go server tests
./tests/run perf     # performance reports
./tests/run loc      # source size report
./tests/run unit/session/main.zsh unit/profile/main.zsh
```
