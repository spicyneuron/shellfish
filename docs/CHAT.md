# Interactive chat

Interactive chat is a controller around bounded `shellfish exec --jsonl` turns. Durable session JSONL is authoritative for session and turn lifecycle. Chat owns transient input, presentation, terminal rendering, and visual reconciliation from that durable state; it must not duplicate locking, hooks, provider requests, tool execution, persistence, or durable turn recovery.

The following module boundaries and invariants define the chat architecture.

## Source organization

```text
lib/
  resume.zsh
  chat/
    main.zsh
    controller.zsh
    transport.zsh
    editor.zsh
    display-fields.jq
    event-decode.jq
    transcript-decode.jq
    render/
      main.zsh
      nodes.zsh
      highlights.zsh
      rows.zsh
      viewport.zsh
      terminal.zsh
      view.zsh
```

The operational chat modules have these responsibilities:

| Module | Responsibility |
| --- | --- |
| `main.zsh` | Restore current presentation configuration, select or create the session, prepare a new frozen runtime and initial durable prefix, then enter the controller. |
| `controller.zsh` | Own chat lifecycle state, prompt sequencing, decoded event application, permissions, cancellation, handoff, presentation reconciliation from the durable session, and the outer editor loop. |
| `transport.zsh` | Start and stop bounded exec, manage its file descriptors, send canonical input and permission responses, buffer and decode JSONL, and report records and completion to the controller. It does not mutate presentation nodes or decide recovery. |
| `editor.zsh` | Own ZLE keymaps, `BUFFER`, `CURSOR`, draft restoration, prompt history, and translation of editor actions into controller intents. It does not own turn state or prompt sequencing. |
| `resume.zsh` | Run the independent pre-chat ZLE application that chooses among supplied session paths. It returns a selection, cancellation, or its own error without depending on chat rendering or chat lifecycle state. |

The rendering modules form a dependency-ordered package. `render/main.zsh` sources them in the order listed below.

| Module | Responsibility |
| --- | --- |
| `nodes.zsh` | Own the width-independent presentation transcript and all semantic node construction and mutation, including durable replay. |
| `highlights.zsh` | Maintain source-indexed syntax highlight spans derived from node content. Its cache follows node mutation and pruning. |
| `rows.zsh` | Project a node suffix into bounded, cell-aware terminal rows with semantic spans and an opaque source cursor for every row. |
| `viewport.zsh` | Build the bounded visible row set, select the settled prefix that may flush, and request highlight checkpoints needed for progress. |
| `terminal.zsh` | Stage and irreversibly install the selected prefix into terminal scrollback, advance the cursor, prune flushed state, and coordinate editor draft preservation across the epoch. |
| `view.zsh` | Assemble the remaining viewport with transient prompt, queue, permission, history, footer, and startup or exit chrome. It reads controller and presentation state but does not change lifecycle state. |

The jq modules are shared projections rather than rendering stages. `display-fields.jq` defines common durable-record display fields, `event-decode.jq` validates and projects live bounded-exec events, and `transcript-decode.jq` validates and replays the durable session prefix.

## State ownership

Every mutable state category has one authoritative owner:

| State | Owner |
| --- | --- |
| Durable session records, validation, locking, and recovery | `lib/session/` and bounded exec |
| Chat lifecycle state and queued turn sequencing | `controller.zsh` |
| Bounded-exec process, file descriptors, input, buffered output, and completion | `transport.zsh` |
| Editor buffer, cursor, draft, keymaps, and prompt history | `editor.zsh` |
| Semantic visible transcript and pending tool pairing | `nodes.zsh` |
| Source-indexed syntax spans | `highlights.zsh` |
| Width-dependent rows and row cursors | `rows.zsh` |
| Current viewport and flush plan | `viewport.zsh` |
| Installed scrollback cursor and pending terminal epoch | `terminal.zsh` |

ZLE callback inversion does not change this ownership. Editor callbacks may invoke controller operations while `vared` owns execution, and transport readiness may wake the controller, but callbacks must not independently implement controller state transitions.

## Turn flow

An ordinary interactive turn follows this sequence:

1. `main.zsh` prepares the current presentation settings and the selected session, then enters the controller.
2. The editor records the submitted prompt in private prompt history and reports it to the controller. The controller appends its transient user presentation and asks the transport to start a bounded turn.
3. The transport runs `shellfish exec --jsonl --session SESSION` and sends one canonical user message on stdin.
4. Bounded exec opens and locks the session, runs prompt hooks, appends the accepted user record, loops over provider responses and tools, recovers the durable turn if needed, then unlocks and exits.
5. The transport buffers complete JSONL records. The controller applies decoded semantic events only after rows from previously applied records have stopped flushing.
6. Node mutation invalidates or advances highlighting. Rows, viewport planning, view assembly, and terminal epochs project the new state without changing the durable session.
7. On normal success, the controller continues from the in-memory presentation transcript. On any uncertain boundary, it reloads durable JSONL and reconciles only the unflushed suffix.

Most slash commands are `user_prompt_submit` hooks. A handled command may emit display context or request a handoff, and the controller exits the current editor before executing that handoff. Commands that affect only local chat state, such as queue editing and quit, do not enter bounded exec.

## Presentation transcript

Think of the presentation transcript as an immutable prefix and a live tail. Only the tail may change. Settling is the one-way movement of text out of that live area: settled text becomes immutable, then bounded ZLE epochs flush its rows into terminal scrollback. Scrollback is permanent and never redrawn or rewrapped.

The presentation transcript is authoritative during an ordinary successful turn. Durable session JSONL remains authoritative for recovery and resume.

### Nodes

A node is one visible semantic unit. Its source—durable replay, submitted input, backend streaming, or transient presentation—is irrelevant after construction.

| Type | Contents and lifecycle |
| --- | --- |
| `section` | Generated role banner. Closed and fully settled when created. Add only when the visible role changes. |
| `activity` | Generic work whose semantic type is not known yet. Open and entirely unsettled; the first semantic event replaces it with the real typed node. |
| `message` | User, system, or assistant body. User and system messages are immediately closed; an assistant message stays open while streaming and closes on commit. |
| `reasoning` | Heading, append-only body, activity state, and optional summary. Open while reasoning streams; closing may append final presentation. |
| `tool_call` | Tool heading and configured call content. Closed when created; its preview policy is independent of the result. |
| `tool_result` | Append-only result, activity state, exit status, and result format. Open until the result arrives; its preview policy is independent of the call. |
| `injection` | Heading and body. Closed and fully settled when created. Durable and visible to the user; provider projection attaches consecutive injections to the next user message. |
| `notice` | Severity, heading, and optional body. Closed and fully settled when created. Ephemeral: it survives redraw and flushing in this process but not resume. |

Nodes obey these invariants:

- Nodes are append-only. At most the final node is open; earlier nodes never change.
- A node has a settled prefix and, while open, an active tail. The settled prefix only grows and is never revised or retracted.
- Closing settles the remainder and may append final presentation; it never rewrites the settled prefix.
- An open node may show activity before it has semantic content. Remove it if it closes empty.
- Generic activity is its own transient node only until the semantic type is known. Once known, activity belongs to the typed node's live header or tail.
- Exactly one blank terminal row separates adjacent visible nodes. There is no leading or trailing blank row; the separator belongs to the following node.
- Nodes store width-independent content and semantic formatting, never terminal colors or wrapped rows.

Tool calls and results form a paired projection. Call rows use a vertical connector and the first result row turns it inward. Reasoning, injections, notices, and tool phases otherwise share a decorated projection: a semantic sigil, optional heading, optional indented content, and an optional active or closing tail. The sigil is a logical rendering seam for construction and styling, not an independently settled terminal fragment.

### Preview policy

Preview configuration selects the projection structure:

- A zero preview is collapsed. While the node is open, its entire sigil-and-heading row remains active. Closing replaces that row with its final heading and settles it atomically. Immediately closed nodes render their final heading directly. Do not wrap the hidden body.
- A positive preview is expanded. Its stable heading and completed visible body rows may settle while activity and the token annotation remain live.
- A full preview is expanded without an elision annotation. Completed body rows may settle while the final partial row remains live.

Event chunking is not a rendering distinction. Construct an open node, append content zero or more times, then close it. Tool results may arrive in one append or as a stream of appends; reasoning uses the same operation for every delta.

Previews have a terminal-row budget. Stop visible layout at the cutoff without wrapping hidden content. Truncated tool calls end with a plain ellipsis; truncated positive tool-result previews report the result's total token count. Zero-result previews use a plain ellipsis. Use a backend count only when it describes that node; otherwise estimate. Apply the configured clamp consistently, including failed tools.

## Rendering pipeline

The primary rendering path is:

```text
nodes + highlights -> rows -> viewport -> terminal scrollback
                              |
                              `-> view + editor chrome
```

The terms have precise meanings:

- A **node** is width-independent semantic content.
- A **highlight** is a source-indexed style span over node content.
- A **row** is a width-dependent terminal projection with a cursor describing its source boundary.
- The **viewport** is the bounded row set safe to expose through ZLE plus the settled prefix eligible to flush.
- A **flush** is the irreversible movement of rows into terminal scrollback.
- The **view** is the unflushed viewport plus transient editor chrome.

The width-independent cursor is the only progress record through the node list. Rows accept these internal cursor forms:

| Form | Meaning |
| --- | --- |
| `NODE:OFFSET` | Resume the ordinary projection at a width-independent text offset. |
| `NODE:OFFSET:PREVIEW_ROWS` | Resume a bounded positive preview after the recorded visible body rows. |
| `NODE:t:OFFSET:HIDDEN` | Resume the generated preview tail; `HIDDEN` records whether body content was elided. |

Other modules treat these cursor values as opaque. A resize rewraps only the unflushed suffix; committed scrollback never changes. Cursor handling must remain valid when fully flushed nodes are dropped.

Terminal rows reserve the final physical column. This prevents an explicit newline from combining with terminal autowrap to create an accidental extra row. Wrapping must remain cell-aware for tabs, combining marks, wide glyphs, oversized words, and explicit newlines.

Terminal pruning creates intentional maintenance edges opposite the primary rendering path: installed rows advance the node cursor, fully flushed nodes are dropped, and highlight caches indexed by those nodes are pruned with them. These operations maintain source-indexed state; they do not redraw scrollback or reverse the rendering pipeline.

## ZLE view and flushing

`PREDISPLAY` is a dangerous staging surface, not scrollback. ZLE permanently truncates `PREDISPLAY` text taller than the available terminal height; the omitted text cannot be recovered by later repainting. Never let accumulated transcript content reach it. Plan bounded viewports and proactively accept epochs so settled rows enter terminal scrollback before the visible prefix exceeds the safe row budget.

Do not rely only on the bounded-exec `zle -F` fd-readiness callback to drive those epochs. Its readiness notification is unreliable on macOS, and a tall asynchronous tail can otherwise remain in one ZLE frame until it is truncated. While work is active, the heartbeat queues an internal ZLE key and keeps scheduling controller steps until every flushable row has entered scrollback. Preserve that independent heartbeat when changing transport, editor callbacks, or repaint timing.

An epoch follows this order:

1. Render a bounded viewport and choose a settled prefix.
2. Stage its text, cursor, highlights, source boundary, and current draft before `accept-line`.
3. Let `zle-line-finish` replace the accepted editor view with the staged rows. ZLE supplies the final newline that installs them in scrollback.
4. Advance and prune presentation state, then let `zle-line-init` restore the draft and paint the remaining viewport.

Never stage a second flush while one is pending. Keep synchronized-output mode balanced across normal completion, cancellation, errors, termination, and handoff.

## Event and recovery rules

- Interactive chat runs turns through `shellfish exec --jsonl`; do not duplicate session or turn lifecycle in chat.
- Provider deltas and control events are transient. Do not add lifecycle or presentation records to durable JSONL.
- Keep pending tool pairing and decoded event batches outside the node list when needed to preserve the one-open-final-node rule.
- Apply buffered transport records in source order, but do not let a later semantic event cross rows from an earlier event that are still eligible to flush.
- On normal success, continue from the in-memory presentation transcript.
- On malformed output, exec failure, cancellation, or any uncertain boundary, stop the turn and rebuild from durable JSONL. Reconcile only the unflushed tail; never rewrite committed scrollback.
- Resume constructs closed nodes from the durable transcript and may drain backlog one bounded viewport at a time. Any extra row or byte cap must still permit progress through an oversized node.

## Resume picker

The resume picker is an independent ZLE application, not a chat view. The CLI discovers candidate sessions and passes their paths to it. The picker summarizes those paths, manages its own keymap and terminal display, and returns one selected path through `REPLY`.

The picker uses the interactive terminal before chat starts, but it does not share chat nodes, highlighting, layout, viewport, themes, transport, controller state, editor keymaps, globals, or errors. The CLI returns picker cancellation or failure directly and starts chat only after a session is selected.
