# Hooks

Hooks are named lifecycle extension points. Each hook runs an ordered list of scripts that supply policy and default behavior (startup context, prompt commands, permission policy, stop continuations) without changing the core agent loop. A hook script is an executable with a small, fixed process contract.

The lifecycle hooks may look familiar to users of Claude Code and Codex, but compatibility is not a goal. Shellfish hook scripts use shell primitives: argv and stdin for input, stdout and stderr for output, fd 3 for structured control, and exit status for flow control. Any overlap is incidental and is not guaranteed.

Bundled scripts and your own scripts use the same contract. The scripts in `share/default/hooks/` are the best reference.

## Lifecycle and ownership

The agent loop, with hooks marked, is:

```text
resolve runtime
if creating a session:
    create header and system record
    run session_start hook scripts
    append startup state and context
open the session for a turn
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

`shellfish create` writes the session header and optional system record before it runs the `session_start` scripts. `shellfish run` owns each complete turn through `user_prompt_submit`, provider requests, tools, permissions, cancellation, and recovery.

Scripts in one turn share ephemeral coordination state through `SHELLFISH_TURN_STATE`. A script runs synchronously. If the operation is cancelled, the running script is terminated but the processes it started are not. Scripts must finish or terminate their own subprocesses before exiting. Daemonizing is unsupported.

## Configuring hooks

Each hook is configured per harness in `shellfish.jsonc` as an ordered list of component references keyed by hook name. Every component is a directory containing an executable `run` and, optionally, a `manifest.json` or `manifest.jsonc`. This example is an excerpt. The bundled `default` harness configures its full chain in [`share/default/shellfish.jsonc`](../share/default/shellfish.jsonc):

```jsonc
{
  "harnesses": {
    "default": {
      "session_start": ["project_environment", "git_environment", "project_instructions"],
      "user_prompt_submit": ["help", "new", "fork", "user_shell"],
      "stop": [],
      "max_capture_bytes": 32768
    }
  }
}
```

These six hook names are the only valid keys: `session_start`, `user_prompt_submit`, `permission_request`, `pre_tool_use`, `post_tool_use`, and `stop`. Any other name is rejected at resolve time. Omitting a hook or giving it an empty list means no components run there.

Reference resolution, most-specific first:

1. an absolute path;
2. `~/...` against `$HOME`;
3. a relative path under `<config-dir>/hooks/<hook>/`, falling back to `share/default/hooks/<hook>/`.

So `"project_environment"` resolves to the component at `share/default/hooks/session_start/project_environment` unless you shadow it with `~/.config/shellfish/hooks/session_start/project_environment`. Hook references must resolve to component directories with executable `run` files. Resolved command paths and manifest environments are stored in the session header, so later configuration changes do not reinterpret an existing session.

A hook manifest contains only its selected environment names:

```json
{"environment":["HOOK_MODE"]}
```

The manifest is optional and defaults to an empty list. See [Configure component environments](CONFIG.md#configure-component-environments) for value resolution and isolation.

## The hook script contract

### Invocation

Every script is invoked with the session working directory as its `PWD` and these exports:

| Variable | Meaning |
| --- | --- |
| `SHELLFISH_SESSION` | Absolute path of the active session JSONL |
| `SHELLFISH_MAX_CAPTURE_BYTES` | Combined output byte limit for one script (`harness.max_capture_bytes`) |
| `SHELLFISH_EXECUTABLE` | Absolute path of the invoked Shellfish executable |
| `SHELLFISH_MODE` | Owning process: `create` for `session_start`, `run` for every turn hook |
| `SHELLFISH_MODEL` | Active model frozen in the session header |
| `SHELLFISH_VERBOSE` | `1` when the chat was started with the `--verbose` presentation override; otherwise `0` |
| `SHELLFISH_CONFIG_DIR` | Directory containing the resolved config file, or its prospective default location |

The initial `PWD` is the working directory frozen in the session header. The script command is a canonical absolute path, so a component can locate adjacent resources from `argv[0]`, such as `${0:A:h}` in zsh.

Scripts on turn-scoped hooks (`user_prompt_submit`, `permission_request`, `pre_tool_use`, `post_tool_use`, and `stop`) also receive `SHELLFISH_TURN_ID` and `SHELLFISH_TURN_STATE`. The turn ID is the one-based ordinal of the next durable user message. The turn derives it before `user_prompt_submit`, reuses it for the accepted turn's later hooks, and discards it when submission is blocked. Turn IDs are not written separately to the session transcript. `SHELLFISH_TURN_STATE` is an absolute path to a private, mode-0700 directory shared by all scripts in that turn.

`$1` is always the hook name. Remaining argv and stdin are hook-specific (see [Hooks](#hooks)).

`SHELLFISH_TURN_STATE` is private to one turn and removed during turn cleanup. Use it to coordinate across scripts in that turn. For example, a `post_tool_use` script can mark the turn dirty and a `stop` script can consume the marker. It is not exported to `session_start` scripts.

### Output channels

A script communicates through three channels. They are captured separately, but their combined size may not exceed `SHELLFISH_MAX_CAPTURE_BYTES`. Each script in a chain receives its own budget. Exceeding it fails the operation without truncating output.

| Channel | Meaning |
| --- | --- |
| stdout | Hook data. Often durable `context`; hook-dependent (see below). |
| stderr | Ephemeral display. Streamed to a live event client while the script runs, never committed, never sent to the model. |
| fd 3 | One JSON control object containing common state and any hook-specific fields. |

fd 3 must contain exactly one JSON object. Every hook accepts an optional `state` array of `{name,value}` objects. The dispatcher constructs canonical state records and removes `state` before the hook-specific adapter validates the remaining fields. The control capture is private and byte-counted before decoding. Model-facing context remains raw stdout, so ordinary scripts can still use `cat` and pipelines without JSON-encoding their payloads.

Hook scripts opt into live display by writing to stderr. In JSONL mode, the first newline-terminated stderr line opens a notice while the script runs; full stderr replaces it after exit and capture checks. A script that writes no newline is displayed only after exit. Silent scripts produce no activity notices. Without a live event stream, the owning process writes the buffered stderr to its own stderr.

stdout and state remain staged until the complete chain and hook-specific validation succeed. Shellfish then appends and emits state followed by any model-facing context. A later script failure discards the chain's staged records. See [JSONL output](RUN.md#output).

### Exit statuses

| Status | Default action | Later scripts in the chain |
| ---: | --- | --- |
| `0` | perform | run |
| `10` | skip | run |
| `11` | skip | skip (halt the chain) |
| other | fail the operation | skip |

Skipping is **sticky**: once any script returns 10 or 11, the default action is disabled for the rest of the chain, and a later `0` does not restore it. The recorded origin is the first script that disabled the default.

Rules the dispatcher enforces for every script:

- Nonempty fd 3 must be one JSON object. Every hook accepts common state; other fields must belong to that hook's control vocabulary.
- stdout is candidate hook data on any successful status; whether it is committed depends on the hook (see below).
- Successful state and stdout accumulate across the chain and become usable only after the whole chain succeeds. A later failure discards all candidate output.
- When a script exits with an unsupported status, its captured stderr is included in the failure message.

Inner commands can return any status. `jq` exiting 1 would otherwise fail the operation, so translate explicitly. The bundled scripts always end with an explicit `exit 0`, `exit 10`, or `exit 11`.

## Hooks

Quick reference. "Owner" is the process that runs the chain; "stdin" is the exact bytes on the script's stdin; "stdout" is what the dispatcher does with stdout; "Control" is the fd-3 vocabulary.

| Hook | Owner | argv (after `$1`) | stdin | stdout | Control (fd 3) | Default / skipped |
| --- | --- | --- | --- | --- | --- | --- |
| `session_start` | create | — | empty | durable context | state | finish creation / unsupported (10/11 fails) |
| `user_prompt_submit` | run | — | exact prompt | durable context | state; context metadata; optional handoff action with exit 11 | submit prompt / do not submit, optionally hand off |
| `permission_request` | run | — | tool request envelope JSON | ignored | state; allow or deny action with exit 11 | defer to adapter / deny, or apply fd 3 |
| `pre_tool_use` | run | — | tool request envelope JSON | denial feedback on exit 10/11 | state | execute / deny the call |
| `post_tool_use` | run | — | tool response envelope JSON | must be empty | state | continue / unsupported (10/11 fails) |
| `stop` | run | `STOP_ATTEMPT` | assistant text | continuation feedback | state | finish turn / commit feedback, request again |

A hook requests durable state with `{"state":[{"name":"git/identity","value":"branch:main"}]}`. State composes with the hook-specific fields in the same object. Records retain configured script and array order, and state is appended before the chain's context.

For context-producing hooks, committed stdout becomes a `context` record named for the hook and attributed to the producing script's basename: `{type:"context",hook:"<hook>",script:"<basename>",content:"<stdout>"}`. For `user_prompt_submit`, a `context` object on fd 3 may add `prompt` and `status` to that script's record. `prompt` requires an integer `status` from 0 through 255.

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

### `session_start`

Runs once after creation writes the session header and optional system record. It does not run when an existing session is resumed or a turn restarts. stdin is empty and `$1` is `session_start`. There are no further arguments. The script does not receive `SHELLFISH_TURN_ID` or `SHELLFISH_TURN_STATE`. Of the environment names declared by configured components, it receives only those selected by its own manifest.

- **stdout** becomes durable `session_start` context. Each script's nonempty stdout is a separately attributed record.
- **stderr** is shown and discarded.
- **fd 3** accepts state.
- **Default action** is finishing creation. Exit 10 or 11 is unsupported and fails session creation without committing hook output.

If a creation script fails or is interrupted by a handled signal, Shellfish removes the new session and reports the failure. Scripts that perform external writes must provide their own idempotency if creation is retried.

```sh
#!/bin/sh
# A minimal session_start hook script: emit one context block and proceed.
set -u
printf 'Workspace\n\n'
pwd -P
exit 0
```

### `user_prompt_submit`

Runs in the turn before the ordinary user record is committed, with the exact submitted prompt on stdin, `$1` = `user_prompt_submit`, and the shared exports including the reserved `SHELLFISH_TURN_ID`. If submission proceeds, scripts on later turn hooks reuse that turn ID. If submission is blocked, Shellfish discards it. Scripts on this hook can implement prompt commands.

- **stdout** becomes durable `user_prompt_submit` context, pending before the next committed user message.
- **stderr** is shown and discarded.
- **fd 3** accepts state and context metadata on any successful script status, plus an optional handoff or session-update action with exit 11.
- **Default action** is submitting the literal prompt. Exit 10 or 11 does not submit it; stdout is still committed.

For a blocked prompt, write model-visible context to stdout and a user-only explanation to stderr. There is no separate block-reason channel.

The supported statuses are:

- **Exit 0** — submit normally. The script did not recognize the input (or only added context).
- **Exit 10** — skip submission and continue the remaining `user_prompt_submit` scripts. Write feedback to stderr and/or context to stdout. A script can attach prompt and status metadata to committed context through fd 3:

  ```json
  {"context":{"prompt":"git status","status":0}}
  ```
- **Exit 11** — skip submission and stop the remaining `user_prompt_submit` scripts. On fd 3, the script may request either `{"action":"handoff","argv":[...]}` with a complete, nonempty command array including the executable as `argv[0]`, or `{"action":"session_update","patch":{...}}` to atomically update the current session runtime.

Only exit 11 can request these actions. Exec applies a session update during the current turn and emits the resulting runtime to the client. The result must be a canonical session runtime. For a handoff, the script only requests it; a capable client executes the command after exec completes cleanly. argv strings must not contain NUL bytes.

A script requesting a session switch writes a JSON action to fd 3:

```zsh
jq -cn --arg command "$SHELLFISH_EXECUTABLE" --arg path "$candidate" \
  '{action:"handoff",argv:[$command,"--session",$path]}' >&3 || exit 1
exit 11
```

### `permission_request`

Runs at the turn's sandbox-bypass decision boundary, only when a tool requests a bypass it is allowed to ask for. It is separate from the `pre_tool_use` policy gate. `$1` is `permission_request`. stdin is a canonical tool request envelope, and the shared exports include the accepted turn's `SHELLFISH_TURN_ID`:

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
- **fd 3** accepts state on any successful status. `{"action":"allow"}` or `{"action":"deny","reason":"..."}` may accompany state and is valid only with exit 11. The reason must be nonempty and may not contain a NUL byte.
- **Default action** (exit 0, default still enabled) is to defer: the turn asks its interactive client, or denies headlessly if no reply is available.
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

Runs immediately before a tool executes. `$1` is `pre_tool_use`. stdin is the same canonical tool request envelope used by `permission_request`.

- **stdout** must be empty on exit 0. On exit 10 or 11, nonempty stdout is denial feedback for the model. Shellfish joins feedback from denying scripts with newlines in configured order and uses it as the denied `tool_result` content. When no denying script writes feedback, the result retains the generic denial text naming the first denying script. Stdout never rewrites tool input.
- **stderr** is shown and discarded.
- **fd 3** accepts state.
- **Default action** is executing the tool. Exit 10 denies the call and continues the script chain. Exit 11 denies the call and halts the chain. Shellfish commits an ordinary `tool_result` with exit code 126, then proceeds to later tool calls in provider order. This policy gate cannot approve sandbox bypass. `permission_request` remains a separate boundary.

Use `SHELLFISH_TURN_STATE` for coordination within the current turn. Request durable cross-turn state through fd 3.

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
- **fd 3** accepts state.
- **Default action** is continuing the tool loop. There is no coherent skipped action, so exit 10 or 11 **fails the operation** (it does not skip anything).

A nonzero tool exit is a normal canonical result, not a script failure, so this script still runs. Script failure is an orchestration failure and triggers ordinary turn recovery. Use turn state to coordinate observations with `stop`. `post_tool_use` cannot replace results or add model context.

### `stop`

Runs after the completed assistant record is committed. `$1` is `stop`, `$2` is the one-based stop-attempt count for the current turn, and stdin is the last assistant message's text blocks concatenated in content order. Non-text blocks are omitted.

- **stdout** is continuation feedback, but only when completion is skipped. Exit-0 stdout is **discarded**: permitting completion must not stage feedback.
- **stderr** is shown and discarded.
- **fd 3** accepts state.
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

- Session transcript records are append-only and authoritative. Hook scripts are trusted user-provided programs. Durable context travels through stdout and durable state through fd 3. Scripts never mutate the transcript directly. Scripts may request a session update through fd 3 but must not rewrite the header directly.
- Script output is untrusted. stdout is escaped before it reaches the model. It cannot forge tags or inject provider roles.
- Dispatch is sequential and preserves configured order. A failed chain commits no staged state or context.
- Captures are private, bounded, and cleaned on every path.
- Scripts have no independent timeout. They must terminate themselves. Cancelling the enclosing operation terminates the active script, but not whatever that script started, and a shell skips its `EXIT` trap when it dies from a signal. A script must not depend on one for anything that matters.
- Scripts inherit the ordinary process environment. Shellfish removes every environment name declared by any component in the frozen runtime, then restores only the names selected by the invoked hook's manifest. The variables documented above are the other Shellfish-specific hook script guarantees.
- Hook scripts are not transformation middleware. Tool-use scripts cannot modify tool input or result content. They observe and gate. Coordinate current-turn policy through turn state, not by overloading stdout.
- Adding a hook is an adapter change, not a dispatcher change. The dispatcher implements the status table, channel limits, and JSON framing. Each hook owns its control fields, default action, and the consequence of skipping it.
