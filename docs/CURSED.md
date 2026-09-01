# Cursed knowledge

## ZLE

ZLE gives us _almost_ everything we want from an editor. It preserves familiar shell editing, history, key bindings, and cursor movement. `PREDISPLAY` even looks like a convenient place to put the transcript, but it has a major limit. Content taller than the terminal is permanently truncated and cannot be recovered into terminal scrollback.

The natural solution is to render the conversation as wrapped visual lines, divided between a settled, immutable transcript and a live, editable tail. As lines accumulate, the tail periodically commits its settled prefix to scrollback, well before reaching the `PREDISPLAY` limit. That part worked. The missing piece was a reliable wake-up trigger. Watching the provider transport was not enough to keep commits and animation moving on macOS, and ZLE provides no timer callback of its own.

The first proof of concept used `zle -U` to inject a synthetic Ctrl-X and dispatch a heartbeat widget. It worked well, but every so often, a heartbeat would land inside a real arrow or function-key sequence, and the entire thing would blow up. Synthetic and terminal input share one queue, so no injected key can be collision-free, and handling every possible collision wasn't practical.

After many, many experiments, Shellfish now watches a small `zpty` clock through `zle -F`. When terminal input is waiting, the clock steps aside. Then the next redraw starts it again. Keyboard bytes remain ZLE's business.

The clock wakes the editor, but its descriptor callback cannot make `accept-line` leave `vared`. Printing settled rows directly looks like the next obvious escape hatch, except ZLE then needs to be told how far the terminal moved. That accounting works... until the terminal scrolls. ZLE's remembers frame starts in the wrong place and the prompt jumps up the screen.

Instead, ZLE now draws the settled rows as its whole display, styling included, then `zle -I` leaves them on screen and resumes beneath them. They become scrollback and the editor rebuilds below without guessing where the terminal went.

The clock has one more consequence. Escape begins arrow and function-key sequences, so ZLE waits before treating a lone Escape as complete. Every tick restarts that wait. Ctrl-C is therefore the only cancellation key, while Escape keeps an inert binding so it cannot combine with the next key into an unintended editor command.

All of that said, this is still preferable to wrestling Bash's Readline into the same job, and considerably smaller than building a full alternate-screen TUI. ZLE gets to remain an editor. Shellfish merely gives it a clock and a careful way to let go of old rows.

## Process groups

Shell process-group control is flaky and incomplete, especially without interactive job control. A test timeout cannot safely kill only its immediate child because background descendants may survive it.

The test runner launches each target through a tiny Python wrapper that calls `os.setsid()` before replacing itself with the target. This gives each test an isolated process group that timeout and cleanup paths can kill as a unit.
