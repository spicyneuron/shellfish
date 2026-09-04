# Shellfish

NOTE: This project is pre-release. Do not add deprecation noticies, backwards compatibility, or test asserting removed functionality.

## Project map

- `bin/shellfish` routes the first argument to an independent component.
- `libexec/` holds independent shell programs, each with its own executable entry point and private implementation. They do not share a shell namespace with the dispatcher or each other.
- `libexec/tui/` owns interactive chat, including session attachment, current presentation configuration, rendering, terminal lifecycle, and the ZLE prompt.
- `libexec/run/` owns the single-turn command: `main.zsh` parses and composes, and its private `turn.zsh` covers input handling, full turns, events, permissions, signals, and cleanup.
- `lib/session/` owns JSONL persistence, state validation, recovery, and provider request projection.
- `lib/runtime/` resolves configuration, credentials, profiles, and schema validation.
- `default/backends/_backend.zsh` supports the bundled provider adapters.
- `libexec/resume/` owns session discovery, latest-session selection, and the resume picker with its private terminal implementation.
- `shellfish-server/` is a Go proxy that exposes one session to one browser, plus the browser client it serves. `docs/SERVER.md` is its contract.
- `default/` is the bundled configuration and reference tools; `docs/HOOKS.md` is the complete hook contract.

## Execution flow

- `bin/shellfish` routes interactive chat and each named command to its program under `libexec/`, where each component owns its parsing.
- `shellfish create` owns session creation. It obtains the frozen runtime by forwarding its unparsed options to `shellfish config` and deleting the presentation fields, prepares the header, concatenates the profile's `system` components into one system record, collects `session_start` context, writes the complete initial JSONL prefix, and prints the path. `--path` chooses the destination; `--session` names the session the runtime is derived from.
- Each turn opens the session, runs `user_prompt_submit` scripts, then loops over provider responses. Final responses run `stop` scripts; tool-call responses run the `pre_tool_use` scripts, permission, execution, persistence, and `post_tool_use` scripts before the next provider request.
- The session layer is authoritative. Request projection converts durable records into provider messages; provider deltas and UI events are transient. Any failure, cancellation, or early return converges on turn recovery and hook/tool cleanup.
- `sf_session_open` resolves which session the TUI or user-facing `run` command attaches to and whether it already exists, invoking `shellfish create` when it does not. The private turn implementation receives the resulting existing session.
- Interactive chat runs single turns through `shellfish run --jsonl`, renders its event stream, and reloads the durable transcript after completion or uncertainty. Transcript replay establishes the frozen runtime from the session header, which live `_session_update` events then refresh.
- A served session runs the same single turns: the proxy relays one child's JSONL to one browser, which replays the durable session on connect and reopens that stream to recover.

## Architecture

- Sessions are append-only JSONL and are the durable source of truth. Every durable prefix must be valid, including an in-progress last turn.
- Durable records are `session`, `system`, `message`, and hook-injected `context`. Provider deltas, turn status, and presentation events are transient.
- Interactive chat submits single turns through the shared session and turn machinery. Do not introduce lifecycle or presentation records.
- Components own their entry points and private implementation under `libexec/`. Shared implementation remains under `lib/`; clients compose work through durable sessions and public `shellfish` commands rather than another component's private functions.
- `libexec/tui/` may use shared session and scratch implementation, the durable session file, public `shellfish create`, `shellfish config`, and `shellfish run` commands, and canonical jq definitions. It must not source turn-private implementation.
- jq module paths are repo-rooted: pass `-L "$SF_ROOT"` and include `lib/runtime/schema`, `lib/session/request`, or `libexec/tui/display-fields`.
- One `shellfish run` process owns a session for the duration of a turn by convention; concurrent writers are not prevented. Keep credentials out of hook scripts; the turn passes the scoped `SHELLFISH_API_KEY` only to the backend adapter.

## Configuration

- User configuration is JSONC at `$XDG_CONFIG_HOME/shellfish/shellfish.jsonc` or `~/.config/shellfish/shellfish.jsonc`; comments are stripped before `jq` processing.
- Profiles compose a backend, a harness, and model/request overrides. Backends define provider adapters and transport; harnesses wrap the shared turn loop with tools, hooks, sandboxing, and limits; top-level themes and `tui` settings define presentation.
- Resolution merges `default/shellfish.jsonc` with user configuration, selects a profile (including its `extend` chain), and resolves referenced files from the config directory before bundled defaults.
- The session header freezes runtime data. Current configuration supplies presentation, so old sessions use the currently selected themes and TUI settings.
- Resolve secrets from the adjacent `.env` or exported variables; exported values win.

## Hooks

- `session_start` runs during session preparation; its output becomes the initial context. `user_prompt_submit`, `permission_request`, `pre_tool_use`, `post_tool_use`, and `stop` run during a turn.
- Hook script stdout supplies model input according to hook policy, stderr is user display only, and fd 3 carries control decisions where supported. Use `docs/HOOKS.md` for payloads, exit statuses, and environment guarantees.

## Development

- For code changes, run the focused unit test nearest the feature first, then `./tests/run unit`. Reserve PTY tests for behavior that requires a real terminal. When running PTY tests, request a run outside the sandbox because otherwise they report `out of pty devices`. Run `./tests/run server` for changes under `shellfish-server/`. It runs the browser and Go tests.
- Treat the worktree as shared: before any `git checkout`, `git restore`, `git reset`, or `git stash`, preserve and review affected uncommitted changes. Never discard or hide another agent's work.
- Do not run tests for documentation- or comment-only changes.
- In Zsh, avoid variable names that collide with special parameters such as `status` and `commands`. When a command substitution's exit status matters, declare the variable first and assign it separately.
- `shellcheck` and `shfmt` are available, although their Zsh support is partial. Address diagnostics when they are relevant and cheap; do not chase every warning.
- Write Markdown as normal paragraphs: do not manually wrap lines.
