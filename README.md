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
- Your **provider** is just a shell script that `curl`s out to APIs and returns JSON. Built-in support for OpenAI, Codex (ChatGPT subscription), Anthropic, OpenRouter, llama.cpp.

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
shellfish --profile PROFILE       # Use another profile, such as readonly
shellfish -m '{"provider": "openrouter", "request": {"model": "MODEL"}}'
                                  # Use the bundled agent without init, with credentials exported

shellfish run "PROMPT"            # Run one non-interactive turn
```

See [providers and credentials](docs/MODELS.md#providers-and-credentials) for supported APIs, Codex login, and OpenAI-compatible services.

Run `shellfish --help` for creation and sandbox options, or `/help` inside chat for commands supplied by the active harness.

For scripts, `--json` returns the final answer, usage, and session path. Reuse the `session` path with `--session` to continue the conversation:

```sh
result=$(shellfish run --json "Summarize this project")
session=$(printf '%s\n' "$result" | jq -r '.session')
shellfish run --json --session "$session" "Inspect the tests next"
```

## Configuration

Shellfish includes a default agent with bundled prompts, tools, commands, and hooks. `init` copies its profile and sandbox settings for customization, plus a read-only example and configuration stubs. General and tool-use prompts remain bundled.

The Shellfish directory (typically `~/.shellfish/`) holds your editable configuration:

- [Profiles](docs/PROFILE.md) in `profiles/` select system prompts, tools, commands, hooks, and sandbox settings.
- [Models](docs/MODELS.md) in `models/` select the provider, endpoint, and request parameters independently of the profile.
- [Sandbox files](docs/PROFILE.md#sandbox) in `sandbox/` enable sandboxing and grant extra paths.
- [Settings](docs/CONFIG.md) keep credentials and limits in `.env` or the environment, and presentation preferences in `tui.jsonc`.

```jsonc
// ~/.shellfish/profiles/review.jsonc
{
  "$schema": "https://raw.githubusercontent.com/spicyneuron/shellfish/refs/heads/main/share/profile.schema.json",
  "sandbox": "default",
  "system": ["general.md", "review.md"],  // ~/.shellfish/system/review.md
  "tools": ["read_file", "shell_readonly"],
  "hooks": ["project/instructions"]
}
```

Add your instructions in `system/review.md`, then select this profile with `shellfish -p review`. New sessions freeze the resolved profile and model. See [Configuration](docs/CONFIG.md) for setup and lookup rules.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): Design intent and opinionated boundaries.
- [`docs/CONFIG.md`](docs/CONFIG.md): Setup, directories, reference lookup, environment, and presentation.
- [`docs/PROFILE.md`](docs/PROFILE.md): Compose agents, configure sandboxing, and choose bundled behavior.
- [`docs/MODELS.md`](docs/MODELS.md): Select models, configure providers, and make standalone requests and decisions.
- [`docs/COMPONENTS.md`](docs/COMPONENTS.md): Write tools, commands, hooks, and providers.
- [`docs/CURSED.md`](docs/CURSED.md): Hard-won lessons and ~~hacks~~ clever workarounds.

## Develop

```sh
./tests/run          # shell tests
./tests/run pty      # terminal integration tests
./tests/run perf     # performance reports
./tests/run loc      # source size report
./tests/run unit/session/main.zsh unit/profile/main.zsh
```
