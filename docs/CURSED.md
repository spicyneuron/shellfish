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

Killing a process without killing what it started is rarely what anyone wants, but zsh cannot reliably help. A shell only puts each job in its own process group when job control is on, and job control needs a controlling terminal, not merely an interactive session: `setopt monitor` succeeds in a plain script attached to a tty and is refused outright without one, which is exactly how `shellfish run` executes under JSONL and the server. A coprocess is no escape. Neither `coproc { ... }` nor `coproc (exec ...)` becomes a group leader; both inherit the caller's group, so `kill -TERM -- "-$pid"` fails and only the immediate child dies. macOS ships no `setsid` binary to borrow.

Shellfish instead borrows a platform launcher. Linux `setsid` replaces itself with a fresh zsh in a new session. macOS has no `setsid` utility, but its `script` command starts its command as the leader of a new process group. The pseudo-terminal carries no component data: a small wrapper redirects stdin, stdout, stderr, and fd 3 to their real files and pipes before starting the component. It records its group and the component's exact exit status out of band. `script` also overwrites the `SCRIPT` environment variable, so the wrapper restores its prior exported state.

Hooks, tools, and backend adapters all use this launcher. Cancellation sends `TERM` and `CONT` to the group, waits briefly, and escalates to `KILL`. Normal completion also kills any remaining group members before waiting for capture EOF. This covers ordinary children and grandchildren without reconstructing a process tree. A process that explicitly calls `setsid()` or `setpgid()` can still escape; daemonizing is unsupported.

The test runner may assume `python3`, which it already requires, and continues to use a tiny `os.setsid()` wrapper around each test. Reconstructing descendants from a `ps` snapshot was tried and removed: it raced against forks and reparenting and failed silently wherever `ps` was unavailable.

An escaped survivor is not merely untidy. It may retain a capture pipe, preventing EOF forever. Cancellation therefore still stops its own readers after group cleanup and accepts whatever output had already arrived.

`zsh/zpty` was evaluated as the launcher and rejected. It also creates a new session and can keep every real channel off its pseudo-terminal, but it forks the current shell. The child inherits Shellfish functions and `zshexit` state unless it executes immediately. That mitigation is what [zsh-workers suggested](https://www.zsh.org/mla/workers/2021/msg00191.html), but the same thread left zpty's EXIT-trap semantics unsettled, and zpty has a [history of mishandling the caller's descriptors](https://zsh-workers.zsh.narkive.com/TCbj2wMa/zsh-4-3-12-subshell-in-midnight-commander-precmd-15-bad-file-descriptor). A spike also lost one successful stderr write. The platform commands add a supervisor on macOS, but they launch a fresh zsh and keep those semantics outside the owning process.
