# Interactive chat

Interactive chat is the default Shellfish mode. Run `shellfish` from your project directory to start a session, send prompts, watch streaming responses and tool calls, and continue the conversation across turns.

## Starting a session

- `shellfish` starts a new session using current configuration.
- `shellfish --session-from PATH` starts a new session with PATH's settings and system prompt.
- `shellfish --continue` reopens the most recent session for this directory.
- `shellfish --resume` opens a picker listing recent sessions for this directory.
- `shellfish --session path/to/session.jsonl` opens a specific session directly.
- `shellfish --draft "prompt"` prefills the editor without submitting the prompt.
- `shellfish --clear` clears the terminal before the first render.
- `shellfish --verbose` lifts all preview limits for the current chat, showing full reasoning, context, and tool output inline.

A new session is created inside chat, and creation presents as a running turn: `session_start` hooks stream their display, a prompt submitted meanwhile joins the queue and is sent once the session exists, and `ctrl+c` cancels creation and requests best-effort cleanup of the published session.

Each session stores its resolved backend, harness, model, and sandbox settings. A fresh `shellfish` launch uses current configuration. `/new` reuses the active session's settings. Themes and TUI preview settings come from current configuration, so they affect how existing sessions are displayed.

Automatic continue and resume discovery considers non-hidden `*.jsonl` files directly in the project session directory. Leading-dot sessions are internal and remain accessible only by explicit path. Resume previews summarize each session's last transcript record, labeling a durable state record with its name.

The default harness compacts a conversation approaching its context window into a child session and opens it with the interrupted prompt as an editable draft. See [Compaction](HARNESS.md#compaction) for the threshold and mechanics.

## Slash commands

Most slash commands are bundled scripts on the default harness's `user_prompt_submit` hook. See [Interactive commands](HARNESS.md#interactive-commands) for the full list and usage. Run `/help` in chat to see the current list.

Chat itself handles `/quit` and the queue commands below. Commands typed while a turn is active are queued and sent after the turn completes.

## Keybindings

| Key | Action |
| --- | --- |
| `enter` | Send the current prompt. |
| `shift+enter` | Insert a newline. |
| `up`, `down` | Navigate prompt history (or move by rendered rows within a multiline prompt). |
| `ctrl+c` | Cancel an active request. Press again to exit when idle. |
| `escape` | Deliberately inert. It cannot combine with the next key into an unintended editor command. |

During a permission request, the keymap switches to accept `a` (approve) or `d` (deny).

## Prompt queue

If you submit a prompt while a turn is still running, it is queued and sent automatically when the turn finishes. Use `/queue drop N` and `/queue clear` to manage queued prompts before they run.

## Preview limits

The TUI collapses long records to a configurable line count. `tui.preview_lines_reasoning`, `preview_lines_context`, `preview_lines_tool_call`, and `preview_lines_tool_result` control how many lines each record type shows in the collapsed view. Set any value to `"full"` to show the entire record, or use `--verbose` to lift all limits for the current chat.

## Recovery

Chat renders from an in-memory presentation transcript during a normal turn. If something goes wrong (malformed output, cancellation, process failure), chat discards the live state and reloads the durable session JSONL. Committed scrollback is never rewritten. You can always recover the ground truth by reopening the session or running `/refresh`.

## Architecture

Interactive chat is a controller around one `shellfish create --jsonl` startup and single `shellfish run --jsonl` turns. Durable session JSONL is the source of truth for session and turn lifecycle. Chat owns only transient input, presentation, terminal rendering, and visual reconciliation. Presentation is resolved from current configuration on each start, never from the session. The session layer handles hooks, provider requests, tool execution, persistence, and recovery.
