# Interactive chat

Interactive chat is the default Shellfish client. It submits each prompt as one turn, presents live activity, and rebuilds conversation history from the durable session transcript.

## Start or reopen a session

- `shellfish` starts a new session using current configuration.
- `shellfish --continue` reopens the most recent session for this directory.
- `shellfish --resume` opens a picker listing recent sessions for this directory.
- `shellfish --session PATH` opens a specific session.

New sessions use current configuration. Existing sessions retain their backend, harness, model, and sandbox settings, while themes and preview settings always come from current configuration.

## Interact

Submit another prompt while a turn is active to queue it for the next turn. Use `/queue drop N` or `/queue clear` to remove queued prompts.

Most slash commands come from the active harness. Run `/help` for the current command list. The client itself owns its queue, refresh, and quit commands so they remain available without running a turn.

| Key | Action |
| --- | --- |
| `enter` | Send the current prompt. |
| `shift+enter` | Insert a newline. |
| `up`, `down` | Navigate prompt history or a multiline prompt. |
| `ctrl+c` | Cancel an active request. Press again to exit when idle. |
| `escape` | No action. |

During a permission request, the keymap switches to accept `a` (approve) or `d` (deny).

## Presentation

The TUI collapses long reasoning and context according to current preview settings. Tool templates are always shown in full. Start chat with `--verbose` to expand reasoning and context inline.

## Recovery

Failed tools, cancellation, and ordinary turn errors are reported without closing chat. If presentation becomes unusable, `/refresh` reopens the session and rebuilds the display from its durable transcript. `/quit` remains available without running a turn.
