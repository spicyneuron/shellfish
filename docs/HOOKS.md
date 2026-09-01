# Hooks

Hooks are named lifecycle extension points. Each hook runs an ordered list of scripts that supply policy and default behavior (startup context, prompt commands, permission policy, stop continuations) without changing the core agent loop. A hook script is an executable with a small, fixed process contract.

The lifecycle hooks may look familiar to users of Claude Code and Codex, but compatibility is not a goal. Shellfish hook scripts use shell primitives: argv and stdin for input, stdout and stderr for output, fd 3 for structured control, and exit status for flow control. Any overlap is incidental and is not guaranteed.

Bundled scripts and your own scripts use the same contract. The scripts in `default/hooks/` are the best reference.

## Lifecycle and ownership

The agent loop, with hooks marked, is:

```text
resolve runtime
if creating a session:
    prepare header
    run system hook components and prepare the system record
    run session_start hook scripts
    create the complete initial prefix
open and lock the session for a turn
run user_prompt_submit hook scripts
append user
repeat:
    build request
    run backend
    append assistant
    if tool calls:
        for each call: run pre_tool_use scripts, execute, run post_tool_use scripts
        continue
    run stop hook scripts
    if completion allowed: finish turn
```

Exec owns hook execution. It runs the `session_start` scripts during lock-free session preparation and creates the durable session after those scripts succeed. It owns each complete locked turn through `user_prompt_submit`, provider requests, tools, permissions, cancellation, and recovery.

Scripts in one turn share ephemeral coordination state, and scripts for one session ID share disposable session state (see `SHELLFISH_TURN_STATE` and `SHELLFISH_SESSION_STATE` below). A script runs synchronously. If the operation is cancelled, in-flight script work is terminated with it. Scripts must finish or terminate their own subprocesses before exiting. Daemonizing is unsupported.

## Configuring hooks

Each hook is configured per harness in `shellfish.jsonc` as an ordered list of component references keyed by hook name. All hooks except `system` require executable scripts. The `system` hook also accepts readable static files:

```jsonc
{
  "harnesses": {
    "default": {
      "system": ["general.md", "tools.md"],
      "session_start": ["add_environment", "add_shell_commands", "add_project_instructions"],
      "user_prompt_submit": ["help", "new", "fork", "user_shell"],
      "stop": [],
      "max_capture_bytes": 32768
    }
  }
}
```

These seven hook names are the only valid keys: `system`, `session_start`, `user_prompt_submit`, `permission_request`, `pre_tool_use`, `post_tool_use`, and `stop`. Any other name is rejected at resolve time. Omitting a hook or giving it an empty list means no components run there.

Reference resolution, most-specific first:

1. an absolute path;
2. `~/...` against `$HOME`;
3. a path with a slash, relative to the config directory;
4. a bare name, resolved against `<config-dir>/hooks/<hook>/` then the bundled `default/hooks/<hook>/`.

So `"add_environment"` resolves to the `add_environment` script at `default/hooks/session_start/add_environment` unless you shadow it with `~/.config/shellfish/hooks/session_start/add_environment`. Ordinary hook references must resolve to executable files. A `system` reference must resolve to a regular file that is readable or executable. Resolved component paths are stored in the session header, so later configuration changes do not reinterpret an existing session. Creating a new session from an existing session rematerializes its frozen system component paths.

## The hook script contract

### Invocation

Every script is invoked with the session working directory as its `PWD` and these exports:

| Variable | Meaning |
| --- | --- |
| `SHELLFISH_SESSION` | Absolute path of the active session JSONL |
| `SHELLFISH_SESSION_ID` | Transcript filename without the `.jsonl` suffix |
| `SHELLFISH_SESSION_STATE` | Absolute path to the disposable, mode-0700 state directory shared by the session ID |
| `SHELLFISH_CAPTURE_LIMIT` | Combined output byte limit for one script (`harness.max_capture_bytes`) |
| `SHELLFISH_EXECUTABLE` | Absolute path of the invoked Shellfish executable |
| `SHELLFISH_MODE` | Invocation mode: `chat` or `exec` |
| `SHELLFISH_MODEL` | Active model frozen in the session header |
| `SHELLFISH_VERBOSE` | `1` when the chat was started with the `--verbose` presentation override; otherwise `0` |
| `PROJECT_DIR` | Working directory frozen in the session header |
| `SHELLFISH_CONFIG_DIR` | Directory containing the resolved config file, or its prospective default location |
| `HOOK_SCRIPT_ROOT` | Directory containing the resolved hook script |

Scripts on turn-scoped hooks (`user_prompt_submit`, `permission_request`, `pre_tool_use`, `post_tool_use`, and `stop`) also receive `SHELLFISH_TURN_ID` and `SHELLFISH_TURN_STATE`. The turn ID is the one-based ordinal of the next durable user message. Exec derives it under the session lock before `user_prompt_submit`, reuses it for the accepted turn's later hooks, and discards it when submission is blocked. Turn IDs are not written separately to the session transcript. `SHELLFISH_TURN_STATE` is an absolute path to a private, mode-0700 directory shared by all scripts in that turn.

`$1` is always the hook name. Remaining argv and stdin are hook-specific (see [Hooks](#hooks)).

`SHELLFISH_TURN_STATE` is private to one turn and removed during turn cleanup. Use it to coordinate across scripts in that turn. For example, a `post_tool_use` script can mark the turn dirty and a `stop` script can consume the marker. It is not exported to `session_start` scripts.

`SHELLFISH_SESSION_STATE` is shared by scripts whose sessions have the same `SHELLFISH_SESSION_ID`. It lives under Shellfish's host temporary root, is retained across ordinary process exits, and is not removed when a turn or chat ends. It is disposable cache state: the host may remove it after a restart or temporary-file cleanup, and a changed `TMPDIR` selects a different location. Scripts must tolerate it being empty. `session_start` receives session state before the transcript file is created; failed session creation does not remove that state.

Both directories are shared writable coordination spaces, not per-script storage. Scripts must namespace files when needed and must account for other Shellfish processes that use the same session ID. The session lock serializes scripts on ordinary turn hooks for one transcript, but intentionally overlapping session IDs may share session state.

### Output channels

A script communicates through three channels. They are captured separately, but their combined size may not exceed `SHELLFISH_CAPTURE_LIMIT`. Each script in a chain receives its own budget. Exceeding it fails the operation without truncating output.

| Channel | Meaning |
| --- | --- |
| stdout | Hook data. Often durable `context`; hook-dependent (see below). |
| stderr | Ephemeral display. Shown to the user, never committed, never sent to the model. |
| fd 3 | One JSON control object on hooks that accept it. |

fd 3 must contain exactly one JSON object. It is captured to a private file and byte-counted before decoding. The dispatcher validates the encoding, and the hook-specific adapter validates the object's fields. Model-facing context remains raw stdout, so ordinary scripts can still use `cat` and pipelines without JSON-encoding their payloads.

### Exit statuses

| Status | Default action | Later scripts in the chain |
| ---: | --- | --- |
| `0` | perform | run |
| `10` | skip | run |
| `11` | skip | skip (halt the chain) |
| other | fail the operation | skip |

Skipping is **sticky**: once any script returns 10 or 11, the default action is disabled for the rest of the chain, and a later `0` does not restore it. The recorded origin is the first script that disabled the default.

Rules the dispatcher enforces for every script:

- fd 3 must be empty unless the hook accepts control. Nonempty fd 3 must be one JSON object; malformed JSON or another JSON type fails the operation.
- stdout is candidate hook data on any successful status; whether it is committed depends on the hook (see below).
- Successful stdout accumulates across the chain and becomes usable only after the whole chain succeeds. A later failure discards all candidate output.
- When a script exits with an unsupported status, its captured stderr is included in the failure message.

Inner commands can return any status. `jq` exiting 1 would otherwise fail the operation, so translate explicitly. The bundled scripts always end with an explicit `exit 0`, `exit 10`, or `exit 11`.

## Hooks

Quick reference. "Owner" is the process that runs the chain; "stdin" is the exact bytes on the script's stdin; "stdout" is what the dispatcher does with stdout; "Control" is the fd-3 vocabulary.

| Hook | Owner | argv (after `$1`) | stdin | stdout | Control (fd 3) | Default / skipped |
| --- | --- | --- | --- | --- | --- | --- |
| `system` | exec | — | empty | durable system text | none | finish creation / unsupported (10/11 fails) |
| `session_start` | exec | — | empty | durable context | none | finish creation / unsupported (10/11 fails) |
| `user_prompt_submit` | exec | — | exact prompt | durable context | context metadata; handoff action with exit 11 | submit prompt / do not submit, optionally hand off |
| `permission_request` | exec | — | tool request envelope JSON | ignored | allow or deny action with exit 11 | defer to adapter / deny, or apply fd 3 |
| `pre_tool_use` | exec | — | tool request envelope JSON | denial feedback on exit 10/11 | none | execute / deny the call |
| `post_tool_use` | exec | — | tool response envelope JSON | must be empty | none | continue / unsupported (10/11 fails) |
| `stop` | exec | `STOP_ATTEMPT` | assistant text | continuation feedback | none | finish turn / commit feedback, request again |

For context-producing hooks, committed stdout becomes a `context` record named for the hook and attributed to the producing script's basename: `{type:"context",hook:"<hook>",script:"<basename>",content:"<stdout>"}`. The `system` hook instead joins its component output into the single system record described below. For `user_prompt_submit`, a `context` object on fd 3 may add `prompt` and `status` to that script's record. `prompt` requires an integer `status` from 0 through 255.

The request builder groups adjacent context records from the same hook into an escaped XML block. Each producing script becomes a nested `context` element; `script`, and when present `prompt` and `status`, are attributes:

```xml
<hook name="user_prompt_submit">
<context script="user_shell" prompt="git status" status="0">
...
</context>
</hook>
```

The hook wrapper keeps injected context distinct from the user request that follows it. Separate durable records retain each script's attribution; grouping happens only in provider request projection.

Trailing context, typically `stop` feedback, becomes a synthetic trailing user message so the transcript does not misattribute it to the human.

### `system`

Runs once during lock-free session preparation before `session_start`. Components are concatenated in configuration order into the session's single durable system record. A `.zsh` file runs through `zsh -f`; another executable file runs directly; another readable file contributes its contents without execution. Executable components receive empty stdin and `$1` = `system`. stdout contributes system text, stderr is shown and discarded, fd 3 is invalid, and any status other than 0 fails creation. Trailing newlines are removed from each nonempty contribution before contributions are joined with a blank line. Each component has its own `max_capture_bytes` budget.

### `session_start`

Runs once during lock-free session preparation. It does not run when an existing session is resumed or exec restarts. The header and configured system record are prepared in memory, and script input is constructed from that state and its resolved runtime. The session path does not exist until the complete initial prefix is written after all scripts succeed. stdin is empty and `$1` is `session_start`. There are no further arguments. The script receives `SHELLFISH_SESSION_STATE`, but it does not receive `SHELLFISH_TURN_ID`, `SHELLFISH_TURN_STATE`, or credentials. The API key is scoped to the backend adapter only.

- **stdout** becomes durable `session_start` context in the initial session prefix. Each script's nonempty stdout is a separately attributed record.
- **stderr** is shown and discarded.
- **fd 3** is invalid; this hook accepts no control.
- **Default action** is finishing creation. Exit 10 or 11 is unsupported and fails exec entry without committing stdout.

If a creation script fails or is interrupted by a handled signal, Shellfish reports the failure and does not create the session file. Scripts that perform external writes must provide their own idempotency if creation is retried.

```sh
#!/bin/sh
# A minimal session_start hook script: emit one context block and proceed.
set -u
[ "$#" -eq 1 ] && [ "$1" = session_start ] || exit 1
printf 'Workspace\n\n'
pwd -P
exit 0
```

### `user_prompt_submit`

Runs in exec before the ordinary user record is committed, with the exact submitted prompt on stdin, `$1` = `user_prompt_submit`, and the shared exports including the reserved `SHELLFISH_TURN_ID`. If submission proceeds, scripts on later turn hooks reuse that turn ID. If submission is blocked, Shellfish discards it. Scripts on this hook can implement prompt commands.

- **stdout** becomes durable `user_prompt_submit` context, pending before the next committed user message.
- **stderr** is shown and discarded.
- **fd 3** accepts context metadata on any successful script status and a handoff action with exit 11.
- **Default action** is submitting the literal prompt. Exit 10 or 11 does not submit it; stdout is still committed.

For a blocked prompt, write model-visible context to stdout and a user-only explanation to stderr. There is no separate block-reason channel.

The supported statuses are:

- **Exit 0** — submit normally. The script did not recognize the input (or only added context).
- **Exit 10** — skip submission without a handoff. Write feedback to stderr and/or context to stdout. A script can attach prompt and status metadata to committed context through fd 3:

  ```json
  {"context":{"prompt":"git status","status":0}}
  ```
- **Exit 11** — skip submission and hand control to a capable client. fd 3 must request `{"action":"handoff","argv":[...]}` with a complete, nonempty command array including the executable as `argv[0]`.

Only exit 11 can request handoff. The script only requests it. A capable client executes the command after exec completes cleanly. argv strings must not contain NUL bytes.

A script requesting a session switch writes a JSON action to fd 3:

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

The chain defers while every script exits 0. Exit 10 denies without a reason but continues the chain. An explicit decision requires exactly one exit-11 script to halt the chain with an fd-3 allow or reasoned-deny action.

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

- **stdout** must be empty on exit 0. On exit 10 or 11, nonempty stdout is denial feedback for the model. Shellfish joins feedback from denying scripts with newlines in configured order and uses it as the denied `tool_result` content. When no denying script writes feedback, the result retains the generic denial text naming the first denying script. Stdout never rewrites tool input.
- **stderr** is shown and discarded.
- **fd 3** is invalid.
- **Default action** is executing the tool. Exit 10 denies the call and continues the script chain. Exit 11 denies the call and halts the chain. Shellfish commits an ordinary `tool_result` with exit code 126, then proceeds to later tool calls in provider order. This policy gate cannot approve sandbox bypass. `permission_request` remains a separate boundary.

Coordinate state beyond denial feedback through `SHELLFISH_TURN_STATE` or `SHELLFISH_SESSION_STATE`. For example, mark a file edit in turn state and consume the marker in a `stop` script.

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
- **Default action** is continuing the tool loop. There is no coherent skipped action, so exit 10 or 11 **fails the operation** (it does not skip anything).

A nonzero tool exit is a normal canonical result, not a script failure, so this script still runs. Script failure is an orchestration failure and triggers ordinary turn recovery. Use turn or session state to coordinate observations with `stop`. `post_tool_use` cannot replace results or add model context.

### `stop`

Runs after the completed assistant record is committed, with exec holding the lock. `$1` is `stop`, `$2` is the one-based stop-attempt count for the current turn, and stdin is the last assistant message's text blocks concatenated in content order. Non-text blocks are omitted.

- **stdout** is continuation feedback, but only when completion is skipped. Exit-0 stdout is **discarded**: permitting completion must not stage feedback.
- **stderr** is shown and discarded.
- **fd 3** is invalid.
- **Default action** (exit 0) is finishing the turn.
- **Skipped** (exit 10 or 11) requires nonempty stdout. That stdout is committed as `stop`-tagged context and forces another provider request within the same turn. Repeated skipped completion is bounded by `harness.max_requests_per_turn`. Scripts can use `$2` to avoid requesting accidental continuation loops.

Exit 10 runs later stop scripts. Exit 11 halts the chain. Both commit feedback and continue. Cancellation stops future work without undoing committed records.

```sh
#!/bin/sh
# Force another request if a tracked file changed during the turn.
set -u
[ -f "$SHELLFISH_TURN_STATE/dirty" ] || exit 0
[ "$2" -le 1 ] || exit 0
printf 'Files changed; re-check your work before stopping.\n'
exit 10
```

## Guarantees and limits

- Session transcript records are append-only and authoritative. Hook scripts are trusted user-provided programs, and durable script output must travel through stdout rather than direct transcript mutation. Scripts may hand off to the locked `--session-update` operation but must not rewrite the header directly.
- Script output is untrusted. stdout is escaped before it reaches the model. It cannot forge tags or inject provider roles.
- Dispatch is sequential and preserves configured order. A failed chain does not commit partial output. Candidate context is usable only after the whole chain succeeds.
- Captures are private, bounded, and cleaned on every path.
- Scripts have no independent timeout. They must terminate themselves. Cancelling the enclosing operation terminates the active script.
- Scripts inherit the process environment, but Shellfish removes built-in provider credentials and the configured backend credential before invocation. Exec scopes that credential to the backend as `SHELLFISH_API_KEY`. The variables documented above are the Shellfish-specific hook script guarantees.
- Session state may be shared by concurrent sessions or processes using the same session ID. Scripts must coordinate access when their data requires it.
- Hook scripts are not transformation middleware. Tool-use scripts cannot modify tool input or result content. They observe and gate. Coordinate policy through turn or session state, not by overloading stdout.
- Adding a hook is an adapter change, not a dispatcher change. The dispatcher implements the status table, channel limits, and JSON framing. Each hook owns its control fields, default action, and the consequence of skipping it.
