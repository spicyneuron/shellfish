# Shellfish

NOTE: This project is pre-release. Do not add deprecation noticies, backwards compatibility, or test asserting removed functionality.

## Project map

- `bin/shellfish` parses the CLI and starts interactive chat or reports resolved configuration.
- `lib/chat/main.zsh` owns interactive session selection, terminal lifecycle, and the ZLE prompt.
- `lib/exec.zsh` owns process setup, input handling, full locked turns, events, permissions, signals, and cleanup.
- `lib/session/` owns JSONL persistence, state validation, recovery, and provider request projection.
- `lib/runtime/` resolves configuration, credentials, profiles, and schema validation.
- `lib/backend.zsh` adapts provider streams.
- `lib/chat/` owns chat rendering and presentation; the independent resume picker lives directly under `lib/`. Keep terminal and ZLE behavior out of exec.
- `cmd/shellfish-server/` is a Go proxy that exposes one session to one browser, plus the browser client it serves. `docs/SERVER.md` is its contract.
- `default/` is the bundled configuration and reference tools; `docs/HOOKS.md` is the complete hook contract.

## Execution flow

- `bin/shellfish` validates CLI input and dispatches to config reporting, single-turn exec, or interactive chat.
- New sessions resolve configuration into a frozen runtime, prepare the header, concatenate the profile's `system` components into one system record, collect `session_start` context, then create the complete initial JSONL prefix without a session lock.
- Each turn opens and locks the session, runs `user_prompt_submit` scripts, then loops over provider responses. Final responses run `stop` scripts; tool-call responses run the `pre_tool_use` scripts, permission, execution, persistence, and `post_tool_use` scripts before the next provider request.
- The session layer is authoritative. Request projection converts durable records into provider messages; provider deltas and UI events are transient. Any failure, cancellation, or early return converges on turn recovery, hook/tool cleanup, and unlock.
- Interactive chat runs single turns through `shellfish exec --jsonl`, renders its event stream, and reloads the durable transcript after completion or uncertainty.
- A served session runs the same single turns: the proxy relays one child's JSONL to one browser, which replays the durable session on connect and reopens that stream to recover.

## Architecture

- Sessions are append-only JSONL and are the durable source of truth. Every durable prefix must be valid, including an in-progress last turn.
- Durable records are `session`, `system`, `message`, and hook-injected `context`. Provider deltas, turn status, and presentation events are transient.
- Interactive chat submits single turns through the shared session and turn machinery. Do not introduce lifecycle or presentation records.
- Session preparation and creation are lock-free; each full turn owns the session lock from open through recovery and cleanup. Keep credentials out of hook scripts; exec passes the scoped `SHELLFISH_API_KEY` only to the backend adapter.

## Configuration

- User configuration is JSONC at `$XDG_CONFIG_HOME/shellfish/shellfish.jsonc` or `~/.config/shellfish/shellfish.jsonc`; comments are stripped before `jq` processing.
- Profiles compose a backend, a harness, and model/request overrides. Backends define provider adapters and transport; harnesses wrap the shared turn loop with tools, hooks, sandboxing, and limits; top-level themes and `tui` settings define presentation.
- Resolution merges `default/shellfish.jsonc` with user configuration, selects a profile (including its `extend` chain), and resolves referenced files from the config directory before bundled defaults.
- The session header freezes runtime data. Current configuration supplies presentation, so old sessions use the currently selected themes and TUI settings.
- Resolve secrets from the adjacent `.env` or exported variables; exported values win.

## Hooks

- `session_start` runs during lock-free session preparation; its output becomes the initial context. `user_prompt_submit`, `permission_request`, `pre_tool_use`, `post_tool_use`, and `stop` run under the full-turn lock.
- Hook script stdout supplies model input according to hook policy, stderr is user display only, and fd 3 carries control decisions where supported. Use `docs/HOOKS.md` for payloads, exit statuses, and environment guarantees.

## Development

- For code changes, run the focused unit test nearest the feature first, then `./tests/run unit`. Reserve PTY tests for behavior that requires a real terminal. When running PTY tests, request a run outside the sandbox because otherwise they report `out of pty devices`. Run `./tests/run server` for changes under `cmd/shellfish-server/`. It runs the browser and Go tests.
- Treat the worktree as shared: before any `git checkout`, `git restore`, `git reset`, or `git stash`, preserve and review affected uncommitted changes. Never discard or hide another agent's work.
- Do not run tests for documentation- or comment-only changes.
- In Zsh, avoid variable names that collide with special parameters such as `status` and `commands`. When a command substitution's exit status matters, declare the variable first and assign it separately.
- `shellcheck` and `shfmt` are available, although their Zsh support is partial. Address diagnostics when they are relevant and cheap; do not chase every warning.
- Write Markdown as normal paragraphs: do not manually wrap lines.
