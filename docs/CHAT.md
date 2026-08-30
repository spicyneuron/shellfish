# Interactive chat

Interactive chat is the default Shellfish mode. Run `shellfish` from your project directory to start a session, send prompts, watch streaming responses and tool calls, and continue the conversation across turns.

## Starting a session

- `shellfish` starts a new session using current configuration.
- `shellfish --new [SESSION]` starts a new session using current configuration or the given session's settings.
- `shellfish --continue` reopens the most recent session for this directory.
- `shellfish --resume` opens a picker listing recent sessions for this directory.
- `shellfish --session path/to/session.jsonl` opens a specific session directly.
- `shellfish --session path/to/session.jsonl --session-update JSON` updates its resolved runtime before opening it.
- `shellfish --draft "prompt"` prefills the editor without submitting the prompt.
- `shellfish --clear` clears the terminal before the first render.
- `shellfish --verbose` lifts all preview limits for the current chat, showing full reasoning, context, and tool output inline.

Each session stores its resolved backend, harness, model, and sandbox settings. A fresh `shellfish` launch uses current configuration. `/new` starts a new session with the active session's settings. Themes and TUI preview settings come from current configuration, so they affect how existing sessions are displayed.

## Slash commands

Most slash commands are `user_prompt_submit` hooks from the default harness. Run `/help` in chat to see the current list.

| Command | Description |
| --- | --- |
| `/help`, `/h` | List available commands. |
| `/new` | Start a new session with the active session's settings. |
| `/fork [N]` | Fork the current transcript into a new session, trimming before the last N user turns and restoring the first removed prompt as a draft. Default N is 0, which forks at the current end without a draft. |
| `/refresh`, `/r` | Rerender the current session from scratch. Fixes layout corruption. |
| `/verbose`, `/v` | Toggle full context, reasoning, and tool output display. |
| `/sandbox [OP DIR]` | List grants, or update and reload with `read` or `write`. Prefix with `-` to remove; `+` is accepted when adding, and signed forms may abbreviate the operation to `r` or `w`. |
| `/server` | Hand the current session to `shellfish-server`. |
| `!command` | Run a shell command and stage its output as context for the next turn. |
| `/queue drop N` | Discard the Nth queued prompt. |
| `/queue clear` | Discard all queued prompts. |
| `/quit`, `/q` | Exit. |

Slash commands that start a new session, fork, refresh, or serve are handoffs: chat exits and relaunches Shellfish with the new session path. Commands typed while a turn is active are queued and sent after the turn completes.

## Keybindings

| Key | Action |
| --- | --- |
| `enter` | Send the current prompt. |
| `shift+enter` | Insert a newline. |
| `up`, `down` | Navigate prompt history (or move by rendered rows within a multiline prompt). |
| `ctrl+c` | Cancel an active request. Press again to exit when idle. |

During a permission request, the keymap switches to accept `a` (approve) or `d` (deny).

## Prompt queue

If you submit a prompt while a turn is still running, it is queued and sent automatically when the turn finishes. Use `/queue drop N` and `/queue clear` to manage queued prompts before they run.

## Preview limits

The TUI collapses long records to a configurable line count. `tui.preview_lines_reasoning`, `preview_lines_context`, `preview_lines_tool_call`, and `preview_lines_tool_result` control how many lines each record type shows in the collapsed view. Set any value to `"full"` to show the entire record, or use `--verbose` to lift all limits for the current chat.

## Recovery

Chat renders from an in-memory presentation transcript during a normal turn. If something goes wrong (malformed output, cancellation, process failure), chat discards the live state and reloads the durable session JSONL. Committed scrollback is never rewritten. You can always recover the ground truth by reopening the session or running `/refresh`.

## Architecture

Interactive chat is a controller around single `shellfish exec --jsonl` turns. Durable session JSONL is the source of truth for session and turn lifecycle. Chat owns only transient input, presentation, terminal rendering, and visual reconciliation. The session layer handles locking, hooks, provider requests, tool execution, persistence, and recovery.
