# Cursed knowledge

## ZLE

ZLE's `PREDISPLAY` is not scrollback. It permanently truncates content taller than the available terminal, while real terminal scrollback cannot be redrawn. Chat keeps the live viewport bounded and incrementally flushes settled rows into scrollback to stay between those constraints.

ZLE also has no reliable wake-up when asynchronous output arrives, possibly due to a macOS-specific issue. Chat injects a synthetic control-X with `zle -U` to dispatch a heartbeat widget. The heartbeat repaints the view and advances pending scrollback flushes.

Even with these workarounds, ZLE is miles ahead of Bash's Readline integration for this job and much simpler than building a full alternate-screen TUI.

## Process groups

Shell process-group control is flaky and incomplete, especially without interactive job control. A test timeout cannot safely kill only its immediate child because background descendants may survive it.

The test runner launches each target through a tiny Python wrapper that calls `os.setsid()` before replacing itself with the target. This gives each test an isolated process group that timeout and cleanup paths can kill as a unit.
