# Hooks

Hooks are ordered executables attached to named lifecycle events. They supply policy and default behavior (startup context, prompt commands, permission policy, stop continuations) without changing the core agent loop. A hook is just a program run with a small, fixed process contract.

The lifecycle events may look familiar to users of Claude Code and Codex, but compatibility is not a goal. Shellfish hooks are designed around shell primitives: argv and stdin for input, stdout and stderr for output, fd 3 for structured control, and exit status for flow control. Any overlap is incidental and is not guaranteed.

Built-in hooks and your own hooks use the same contract. The bundled hooks in `default/hooks/` are ordinary scripts and are the best reference.

## Lifecycle and ownership

The agent loop, with hooks marked, is:

```text
resolve runtime
if creating a session:
    prepare header and system record
    run session_start hooks
    create the complete initial prefix
open and lock the session for a turn
run user_prompt_submit hooks
append user
repeat:
    build request
    run backend
    append assistant
    if tool calls:
        for each call: run pre_tool_use, execute, run post_tool_use
        continue
    run stop hooks
    if completion allowed: finish turn
```

Exec owns hooks. It runs `session_start` during lock-free session preparation and creates the durable session after those hooks succeed. It owns each complete locked turn through `user_prompt_submit`, provider requests, tools, permissions, cancellation, and recovery.

Hooks in one creation or turn operation share an ephemeral coordination directory (see `SHELLFISH_STATE_DIR` below). A hook runs synchronously. If the operation is cancelled, in-flight hook work is terminated with it. Hooks must finish or terminate their own subprocesses before exiting. Daemonizing is unsupported.

## Configuring hooks

Hooks are configured per harness in `config.jsonc`, as ordered lists of references keyed by event name:

```jsonc
{
  "harnesses": {
    "default": {
      "session_start": ["add_environment", "add_command_availability", "add_project_instructions"],
      "user_prompt_submit": ["help", "new", "fork", "user_shell"],
      "stop": [],
      "max_capture_bytes": 32768
    }
  }
}
```

The six event names are the only valid keys (`session_start`, `user_prompt_submit`, `permission_request`, `pre_tool_use`, `post_tool_use`, and `stop`); any other name is rejected at resolve time. Omitting an event or giving an empty list means no hooks run for it.

Reference resolution, most-specific first:

1. an absolute path;
2. `~/...` against `$HOME`;
3. a path with a slash, relative to the config directory;
4. a bare name, resolved against `<config-dir>/hooks/<event>/` then the bundled `default/hooks/<event>/`.

So `"add_environment"` resolves to `default/hooks/session_start/add_environment` unless you shadow it with `~/.config/shellfish/hooks/session_start/add_environment`. Each reference must resolve to an executable file, or runtime resolution fails. Resolved paths are frozen into the session header, so an existing session keeps the hooks it started with even if config changes.

## The hook contract

### Invocation

Every hook is invoked with the session working directory as its `PWD` and these exports:

| Variable | Meaning |
| --- | --- |
| `SHELLFISH_SESSION` | Absolute path of the active session JSONL |
| `SHELLFISH_SESSION_ID` | Transcript filename without the `.jsonl` suffix |
| `SHELLFISH_STATE_DIR` | Ephemeral, mode-0700 coordination directory |
| `SHELLFISH_CAPTURE_LIMIT` | Combined output byte limit for one hook (`harness.max_capture_bytes`) |
| `SHELLFISH_EXECUTABLE` | Absolute path of the invoked Shellfish executable |
| `SHELLFISH_MODE` | Invocation mode: `chat` or `exec` |
| `SHELLFISH_MODEL` | Active model frozen in the session header |
| `SHELLFISH_VERBOSE` | `1` when the chat was started with the `--verbose` presentation override; otherwise `0` |
| `PROJECT_DIR` | Working directory frozen in the session header |
| `PLUGIN_ROOT` | Directory containing the resolved hook executable |
| `PLUGIN_DATA` | Persistent, mode-0700 data directory for the event and hook name |

Turn-scoped hooks (`user_prompt_submit`, `permission_request`, `pre_tool_use`, `post_tool_use`, and `stop`) also receive `SHELLFISH_TURN_ID`. It is the one-based ordinal of the next durable user message. Exec derives it under the session lock before `user_prompt_submit`, reuses it for the accepted turn's later hooks, and discards it when submission is blocked. Turn IDs are not written separately to the session transcript.

`$1` is always the event name. Remaining argv and stdin are event-specific (see [Events](#events)).

`SHELLFISH_STATE_DIR` is private to one creation or turn operation and shared by its hooks. It is removed on teardown. Do not store anything durable there. Use it to coordinate across hooks within a turn. For example, a `post_tool_use` hook marks a turn dirty and a `stop` hook consumes the marker.

`PLUGIN_DATA` persists across invocations under `${XDG_STATE_HOME:-$HOME/.local/state}/shellfish/hooks/<event>/<hook-name>`. A bundled hook and a user hook shadowing it share persistent data when they have the same event and basename. Hooks should use `PLUGIN_DATA` for durable hook-owned data and `SHELLFISH_STATE_DIR` only for coordination within the current operation.

### Output channels

A hook communicates through three channels. They are captured separately, but their combined size may not exceed `SHELLFISH_CAPTURE_LIMIT`. Each hook in a chain receives its own budget. Exceeding it fails the operation without truncating output.

| Channel | Meaning |
| --- | --- |
| stdout | Event data. Often durable `context`; event-dependent (see below). |
| stderr | Ephemeral display. Shown to the user, never committed, never sent to the model. |
| fd 3 | One JSON control object on events that accept it. |

fd 3 must contain exactly one JSON object. It is captured to a private file and byte-counted before decoding. The dispatcher validates the encoding, and the event adapter validates the object's fields. Model-facing context remains raw stdout, so ordinary hooks can still use `cat` and pipelines without JSON-encoding their payloads.

### Exit statuses

| Status | Default action | Later hooks in the chain |
| ---: | --- | --- |
| `0` | perform | run |
| `10` | skip | run |
| `11` | skip | skip (halt the chain) |
| other | fail the operation | skip |

Skipping is **sticky**: once any hook returns 10 or 11, the default action is disabled for the rest of the chain, and a later `0` does not restore it. The recorded origin is the first hook that disabled the default.

Rules the dispatcher enforces for every event:

- fd 3 must be empty unless the event accepts control. Nonempty fd 3 must be one JSON object; malformed JSON or another JSON type fails the operation.
- stdout is candidate event data on any successful status; whether it is committed depends on the event (see below).
- Successful stdout accumulates across the chain and becomes usable only after the whole chain succeeds. A later failure discards all candidate output.
- When a hook exits with an unsupported status, its captured stderr is included in the failure message.

Inner commands can return any status. `jq` exiting 1 would otherwise fail the operation, so translate explicitly. The bundled hooks always end with an explicit `exit 0`, `exit 10`, or `exit 11`.

## Events

Quick reference. "Owner" is the process that runs the chain; "stdin" is the exact bytes on the hook's stdin; "stdout" is what the dispatcher does with stdout; "Control" is the fd-3 vocabulary.

| Event | Owner | argv (after `$1`) | stdin | stdout | Control (fd 3) | Default / skipped |
| --- | --- | --- | --- | --- | --- | --- |
| `session_start` | exec | — | empty | durable context | none | finish creation / unsupported (10/11 fails) |
| `user_prompt_submit` | exec | — | exact prompt | durable context | context metadata; handoff action with exit 11 | submit prompt / do not submit, optionally hand off |
| `permission_request` | exec | — | tool request envelope JSON | ignored | allow or deny action with exit 11 | defer to adapter / deny, or apply fd 3 |
| `pre_tool_use` | exec | — | tool request envelope JSON | denial feedback on exit 10/11 | none | execute / deny the call |
| `post_tool_use` | exec | — | tool response envelope JSON | must be empty | none | continue / unsupported (10/11 fails) |
| `stop` | exec | `STOP_ATTEMPT` | assistant text | continuation feedback | none | finish turn / commit feedback, request again |

When stdout is committed, it becomes a `context` record tagged with the event name and the producing hook's basename: `{type:"context",tag:"<event>", hook:"<basename>",content:"<stdout>"}`. For `user_prompt_submit`, a `context` object on fd 3 may add `prompt` and `status` to that hook's record. `prompt` requires an integer `status` from 0 through 255.

The request builder folds each run into an escaped XML block. The event is the element name; `hook`, and when present `prompt` and `status`, are attributes:

```xml
<user_prompt_submit hook="user_shell" prompt="git status" status="0">
...
</user_prompt_submit>
```

Trailing context, typically `stop` feedback, becomes a synthetic trailing user message so the transcript does not misattribute it to the human.

### `session_start`

Runs once during lock-free session preparation. It does not run when an existing session is resumed or exec restarts. The header and configured system record are prepared in memory, and hook input is constructed from that state and its frozen runtime. The session path does not exist until the complete initial prefix is written after all hooks succeed. stdin is empty and `$1` is `session_start`. There are no further arguments. The hook does not receive `SHELLFISH_TURN_ID` or credentials. The API key is scoped to the backend adapter only.

- **stdout** becomes durable `session_start` context in the initial session prefix. Each hook's nonempty stdout is a separately attributed record.
- **stderr** is shown and discarded.
- **fd 3** is invalid; this event accepts no control.
- **Default action** is finishing creation. Exit 10 or 11 is unsupported and fails exec entry without committing stdout.

`add_environment` prints date, platform, working directory, a directory tree, and git state to stdout. `add_command_availability` reports the host Zsh version and the first available command and version in common command groups. Missing commands and unsupported version flags are omitted. `add_project_instructions` prints `AGENTS.md` from the session working directory, or `CLAUDE.md` when `AGENTS.md` is absent. Creation-only execution prevents this durable context from being repeated on resume.

If a creation hook fails or is interrupted by a handled signal, Shellfish reports the failure and does not create the session file. Hooks that perform external writes must provide their own idempotency if creation is retried.

```sh
#!/bin/sh
# A minimal session_start hook: emit one context block and proceed.
set -u
[ "$#" -eq 1 ] && [ "$1" = session_start ] || exit 1
printf 'Workspace\n\n'
pwd -P
exit 0
```

### `user_prompt_submit`

Runs in exec before the ordinary user record is committed, with the exact submitted prompt on stdin, `$1` = `user_prompt_submit`, and the shared exports including the reserved `SHELLFISH_TURN_ID`. If submission proceeds, later turn hooks reuse that turn ID. If submission is blocked, Shellfish discards it. Hooks can use this event to implement prompt commands.

- **stdout** becomes durable `user_prompt_submit` context, pending before the next committed user message.
- **stderr** is shown and discarded.
- **fd 3** accepts context metadata on any successful hook status and a handoff action with exit 11.
- **Default action** is submitting the literal prompt. Exit 10 or 11 does not submit it; stdout is still committed.

For a blocked prompt, write model-visible context to stdout and a user-only explanation to stderr. There is no separate block-reason channel.

The supported statuses are:

- **Exit 0** — submit normally. The hook did not recognize the input (or only added context).
- **Exit 10** — skip submission without a handoff. Write feedback to stderr and/or context to stdout. A hook can attach prompt and status metadata to committed context through fd 3:

  ```json
  {"context":{"prompt":"git status","status":0}}
  ```
- **Exit 11** — skip submission and hand control to a capable client. fd 3 must request `{"action":"handoff","argv":[...]}` with a complete, nonempty command array including the executable as `argv[0]`.

Only exit 11 can request handoff. The hook only requests it. A capable client executes the command after exec completes cleanly. argv strings must not contain NUL bytes.

A hook requesting a session switch writes a JSON action to fd 3:

```zsh
jq -cn --arg command "$SHELLFISH_EXECUTABLE" --arg path "$candidate" \
  '{action:"handoff",argv:[$command,"--session",$path]}' >&3 || exit 1
exit 11
```

### `permission_request`

Runs at exec's sandbox-bypass decision boundary, only when a tool requests a bypass it is allowed to ask for. It is separate from the `pre_tool_use` policy gate. `$1` is `permission_request`. stdin is a canonical tool request envelope, and the shared exports include the accepted turn's `SHELLFISH_TURN_ID`:

```json
{
  "turn_id": 1,
  "tool_name": "shell",
  "tool_use_id": "call_1",
  "tool_input": {"command": "true", "request_sandbox_bypass": true}
}
```

- **stdout** is captured but ignored. It is not committed.
- **stderr** is shown and discarded.
- **fd 3** is `{"action":"allow"}` or `{"action":"deny","reason":"..."}`. The reason must be nonempty and may not contain a NUL byte. Valid only with exit 11.
- **Default action** (exit 0, default still enabled) is to defer: exec asks its interactive client, or denies headlessly if no reply is available.
- **Skipped without control** (exit 10) denies.
- **Skipped with control** (exit 11) applies the fd-3 decision. An invalid decision fails the operation.

The chain defers while every hook exits 0. Exit 10 denies without a reason but continues the chain. An explicit decision requires exactly one exit-11 hook to halt the chain with an fd-3 allow or reasoned-deny action.

```zsh
#!/usr/bin/env zsh
# Allow bypasses only inside a known project tree; otherwise deny with a reason.
emulate -R zsh
case "$SHELLFISH_SESSION" in
  */my-project/*)
    print -rn -u3 -- '{"action":"allow"}' || exit 1
    exit 11
    ;;
esac
jq -cn --arg reason 'bypass denied outside the project tree' \
  '{action:"deny",reason:$reason}' >&3 || exit 1
exit 11
```

### `pre_tool_use`

Runs immediately before a tool executes, with exec holding the session lock. `$1` is `pre_tool_use`. stdin is the same canonical tool request envelope used by `permission_request`.

- **stdout** must be empty on exit 0. On exit 10 or 11, nonempty stdout is denial feedback for the model. Shellfish joins feedback from denying hooks with newlines in configured order and uses it as the denied `tool_result` content. When no denying hook writes feedback, the result retains the generic denial text naming the first denying hook. Stdout never rewrites tool input.
- **stderr** is shown and discarded.
- **fd 3** is invalid.
- **Default action** is executing the tool. Exit 10 denies the call and continues the hook chain. Exit 11 denies the call and halts the chain. Shellfish commits an ordinary `tool_result` with exit code 126, then proceeds to later tool calls in provider order. This policy gate cannot approve sandbox bypass. `permission_request` remains a separate boundary.

Coordinate state beyond denial feedback through `SHELLFISH_STATE_DIR`. For example, mark a file edit here and consume the marker in a `stop` hook.

### `post_tool_use`

Runs after the canonical tool result is durably committed. `$1` is `post_tool_use`. stdin is a canonical tool response envelope containing the original input and the committed result:

```json
{
  "turn_id": 1,
  "tool_name": "shell",
  "tool_use_id": "call_1",
  "tool_input": {"command": "true"},
  "tool_response": {
    "content": "",
    "exit_code": 0
  }
}
```

- **stdout** must be empty.
- **stderr** is shown and discarded.
- **fd 3** is invalid.
- **Default action** is continuing the tool loop. There is no coherent skipped action, so exit 10 or 11 **fails the event** (it does not skip anything).

A nonzero tool exit is a normal canonical result, not a hook failure, so this hook still runs. Hook failure is an orchestration failure and triggers ordinary turn recovery. Use `SHELLFISH_STATE_DIR` or `PLUGIN_DATA` to coordinate observations with `stop`. `post_tool_use` cannot replace results or add model context.

### `stop`

Runs after the completed assistant record is committed, with exec holding the lock. `$1` is `stop`, `$2` is the one-based stop-attempt count for the current turn, and stdin is the last assistant message's text blocks concatenated in content order. Non-text blocks are omitted.

- **stdout** is continuation feedback, but only when completion is skipped. Exit-0 stdout is **discarded**: permitting completion must not stage feedback.
- **stderr** is shown and discarded.
- **fd 3** is invalid.
- **Default action** (exit 0) is finishing the turn.
- **Skipped** (exit 10 or 11) requires nonempty stdout. That stdout is committed as `stop`-tagged context and forces another provider request within the same turn. Repeated skipped completion is bounded by `harness.max_requests_per_turn`. Hooks can use `$2` to avoid requesting accidental continuation loops.

Exit 10 runs later stop hooks. Exit 11 halts the chain. Both commit feedback and continue. Cancellation stops future work without undoing committed records.

```sh
#!/bin/sh
# Force another request if a tracked file changed during the turn.
set -u
[ -f "$SHELLFISH_STATE_DIR/dirty" ] || exit 0
[ "$2" -le 1 ] || exit 0
printf 'Files changed; re-check your work before stopping.\n'
exit 10
```

## Guarantees and limits

- The session JSONL is append-only and authoritative. Hooks are trusted user-provided programs, and durable hook output must travel through stdout rather than direct transcript mutation.
- Hook output is untrusted. stdout is escaped before it reaches the model. It cannot forge tags or inject provider roles.
- Dispatch is sequential and preserves configured order. A failed chain does not commit partial output. Candidate context is usable only after the whole chain succeeds.
- Captures are private, bounded, and cleaned on every path.
- Hooks have no independent timeout. They must terminate themselves. Cancelling the enclosing operation terminates the active hook.
- Hooks inherit the process environment, but Shellfish removes built-in provider credentials and the configured backend credential before invocation. Exec scopes that credential to the backend as `SHELLFISH_API_KEY`. The variables documented above are the Shellfish-specific hook guarantees.
- `PLUGIN_DATA` may be shared by concurrent sessions or processes. Hooks must coordinate access when their persistent data requires it.
- Hooks are not transformation middleware. Tool-use hooks cannot modify tool input or result content. They observe and gate. Coordinate policy through `SHELLFISH_STATE_DIR`, not by overloading stdout.
- Adding an event is an adapter change, not a dispatcher change. The dispatcher implements the status table, channel limits, and JSON framing. Each event owns its control fields, default action, and the consequence of skipping it.
