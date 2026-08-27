# Shellfish

## Project map

- `bin/shellfish` parses the CLI and starts interactive chat or reports resolved configuration.
- `lib/chat/main.zsh` owns interactive session selection, terminal lifecycle, and the ZLE prompt.
- `lib/exec.zsh` owns process setup, input handling, full locked turns, events, permissions, signals, and cleanup.
- `lib/session/` owns JSONL persistence, state validation, recovery, and provider request projection.
- `lib/runtime/` resolves configuration, credentials, profiles, and schema validation.
- `lib/backend.zsh` adapts provider streams.
- `lib/chat/` owns chat rendering and presentation; the independent resume picker lives directly under `lib/`. Keep terminal and ZLE behavior out of exec.
- `server/` is a Go proxy that exposes one session to one browser, plus the browser client it serves; `docs/SERVER.md` is its contract.
- `default/` is the bundled configuration and reference tools; `docs/HOOKS.md` is the complete hook contract.

## Execution flow

- `bin/shellfish` validates CLI input and dispatches to config reporting, bounded exec, or interactive chat.
- New sessions resolve configuration into a frozen runtime, prepare the header and system record in memory, collect `session_start` context, then create the complete initial JSONL prefix without a session lock.
- Each turn opens and locks the session, runs prompt hooks, then loops over provider responses. Final responses run stop hooks; tool-call responses run the pre-hook, permission, execution, persistence, and post-hook pipeline before the next provider request.
- The session layer is authoritative. Request projection converts durable records into provider messages; provider deltas and UI events are transient. Any failure, cancellation, or early return converges on turn recovery, hook/tool cleanup, and unlock.
- Interactive chat runs bounded turns through `shellfish exec --jsonl`, renders its event stream, and reloads the durable transcript after completion or uncertainty.
- A served session runs the same bounded turns: the proxy relays one child's JSONL to one browser, which replays the durable session on connect and reopens that stream to recover.

## Architecture

- Sessions are append-only JSONL and are the durable source of truth. Every durable prefix must be valid, including an in-progress last turn.
- Durable records are `session`, `system`, `message`, and hook-injected `context`. Provider deltas, turn status, and presentation events are transient.
- Interactive chat submits bounded turns through the shared session and turn machinery. Do not introduce lifecycle or presentation records.
- Session preparation and creation are lock-free; each full turn owns the session lock from open through recovery and cleanup. Keep credentials out of hooks; exec passes the scoped `SHELLFISH_API_KEY` only to the backend adapter.

## Configuration

- User configuration is JSONC at `$XDG_CONFIG_HOME/shellfish/config.jsonc` or `~/.config/shellfish/config.jsonc`; comments are stripped before `jq` processing.
- Profiles compose a backend, a harness, model/request overrides, and theme selections. Backends define provider adapters and transport; harnesses wrap the shared turn loop with system prompts, tools, hooks, sandboxing, and limits; themes and `tui` define presentation.
- Resolution merges `default/config.jsonc` with user configuration, selects a profile (including its `extend` chain), and resolves referenced files from the config directory before bundled defaults.
- The session header freezes runtime data. Current configuration supplies presentation, so old sessions use current themes and TUI settings, but their frozen theme names must still exist.
- Resolve secrets from the adjacent `.env` or exported variables; exported values win.

## Hooks

- `session_start` runs during lock-free session preparation and its context becomes part of the initial prefix. `user_prompt_submit`, `permission_request`, `pre_tool_use`, `post_tool_use`, and `stop` run under the full-turn lock.
- Hook stdout supplies context according to event policy, stderr is user display only, and fd 3 carries control decisions. Use `docs/HOOKS.md` for payloads, exit statuses, and environment guarantees.

## Development

- For code changes, run the focused unit test nearest the feature first, then `./tests/run unit`. Run `./tests/run pty` when terminal or UI behavior is relevant. Run `./server/test` for changes under `server/`; it runs the browser tests and then the Go tests.
- Treat the worktree as shared: before any `git checkout`, `git restore`, `git reset`, or `git stash`, preserve and review affected uncommitted changes. Never discard or hide another agent's work.
- Do not run tests for documentation- or comment-only changes.
- `shellcheck` and `shfmt` are available, although their Zsh support is partial. Address diagnostics when they are relevant and cheap; do not chase every warning.
- Write Markdown as normal paragraphs: do not manually wrap lines.
