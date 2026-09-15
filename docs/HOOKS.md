# Hooks

Hooks are ordered shell scripts bound to lifecycle points. They add context and workflow policy without changing the core agent loop. Bundled and custom hooks use the same process contract. [`share/default/hooks/`](../share/default/hooks/) contains the authoritative examples.

## Lifecycle and ownership

Hooks surround the durable operations owned by session creation and a turn:

```text
create session
    session_start
begin turn
    user_prompt_submit
append user
repeat:
    append assistant
    if tool calls:
        for each call:
            pre_tool_use
            permission_request when execution needs approval
            execute or deny tool
            post_tool_use
        continue
    stop
    if completion allowed: finish turn
```

Hooks can influence whether work proceeds, but the core retains event ordering, transcript mutation, recovery, and cleanup.

## Configuring hooks

Each hook is configured on a harness as an ordered list of component references. A component directory contains an executable `run` and an optional JSON manifest:

```jsonc
{
  "harnesses": {"default": {
    "session_start": ["project_environment", "project_instructions"],
    "user_prompt_submit": ["help", "user_shell"]
  }}
}
```

A manifest can select component-specific values to load from `.env` and set a running display label:

```json
{"environment":["HOOK_MODE"],"running":"Checking the working tree"}
```

`user_prompt_submit` components may also declare a regular-expression or executable `match` selector and optional help metadata:

```json
{"match":{"pattern":"^/review\\z"},"help":{"usage":"/review","description":"Review changes"}}
```

Selectors run before the component and retain configured order. A command selector receives the same invocation context as `run`, must produce no output, and selects on exit 0, skips on exit 1, or fails otherwise. See [Configuration](CONFIG.md#customize-a-harness) for component lookup and environment rules.

## The hook script contract

Scripts run from the session working directory. `$1` is the hook name. Remaining arguments and stdin are hook-specific. Shellfish exports:

| Variable | Meaning |
| --- | --- |
| `SHELLFISH_SESSION` | Absolute path of the active session JSONL |
| `SHELLFISH_MAX_CAPTURE_BYTES` | Combined byte limit across stdout, stderr, and fd 3 |
| `SHELLFISH_EXECUTABLE` | Absolute path of the invoked Shellfish executable |
| `SHELLFISH_MODE` | Owning process: `create` for `session_start`, `run` for every turn hook |
| `SHELLFISH_MODEL` | Active model frozen in the session header |
| `SHELLFISH_VERBOSE` | `1` when full presentation was requested, otherwise `0` |
| `SHELLFISH_CONFIG_DIR` | Directory containing the config file, or its prospective default |

Turn hooks also receive `SHELLFISH_TURN_ID`, the one-based ordinal of the next durable user message, and `SHELLFISH_TURN_STATE`, a private directory shared by scripts in that turn. `session_start` receives neither. Use turn state for ephemeral coordination and fd 3 for durable state.

Scripts communicate through three bounded channels:

| Channel | Meaning |
| --- | --- |
| stdout | Durable model context, preserved verbatim |
| stderr | Durable user-only output, preserved verbatim |
| fd 3 | One JSON control object for durable state and hook-specific decisions |

fd 3, when used, must contain exactly one object. Every hook accepts `{"state":[{"name":"example","value":true}]}`. Additional control fields depend on the hook. State names are at most 128 characters and match `^[A-Za-z0-9][A-Za-z0-9_.:/-]*$`. Valid state and hook output become durable in that order before the next component runs. Scripts never write the transcript directly.

Exit status controls the default action and the remaining chain:

| Status | Default action | Later scripts in the chain |
| ---: | --- | --- |
| `0` | perform | run |
| `10` | skip | run |
| `11` | skip | skip (halt the chain) |
| other | fail the operation | skip |

Skipping is sticky: after one script returns 10 or 11, a later zero does not restore the default action.

## Hooks

| Hook | stdin | Default action | Skip action |
| --- | --- | --- | --- |
| `session_start` | empty | finish creation | unsupported |
| `user_prompt_submit` | exact prompt | submit prompt | block submission |
| `permission_request` | tool request JSON | defer to client | deny or apply a decision |
| `pre_tool_use` | tool request JSON | execute tool | deny tool |
| `post_tool_use` | tool response JSON | continue | unsupported |
| `stop` | final assistant text | finish turn | add feedback and continue |

Hook stdout becomes attributed model context. Stderr becomes attributed user-only output. These meanings do not change with lifecycle or exit status.

Tool hooks receive canonical envelopes. A request envelope has:

```json
{"turn_id":1,"tool_name":"shell","tool_use_id":"call_1","tool_input":{"command":"true"}}
```

A response envelope adds the committed result:

```json
{
  "turn_id": 1,
  "tool_name": "shell",
  "tool_use_id": "call_1",
  "tool_input": {"command": "true"},
  "tool_response": {"stdout": "", "stderr": "", "exit_code": 0}
}
```

### `session_start`

Runs once after the session header and optional system record are created.

- **argv:** `session_start`
- **stdin:** empty
- **stdout:** durable startup model context
- **stderr:** durable user-only output
- **fd 3:** state
- **Exit 0:** finish creation
- **Exit 10 or 11:** unsupported and fail creation

### `user_prompt_submit`

Runs before the user record is committed.

- **argv:** `user_prompt_submit`
- **stdin:** exact submitted prompt
- **stdout:** durable model context immediately before the prompt
- **stderr:** durable user-only output
- **fd 3:** state, optional `{"context":{"prompt":"...","status":0}}` metadata with nonempty stdout where status is 0–255, and with exit 11, `{"action":"handoff","argv":[...]}` containing a complete command or `{"action":"session_update","patch":{...}}`
- **Exit 0:** submit the literal prompt
- **Exit 10:** block submission and continue the hook chain
- **Exit 11:** block submission, halt the chain, and optionally apply its action

Valid output remains durable when submission is blocked. A handoff is only a request. A capable client performs it after the turn exits cleanly. A session update may patch `profile`, `backend`, or `harness`. Shellfish applies it only when the resulting runtime is valid.

### `permission_request`

Runs when a tool requests a supported sandbox bypass. This decision is separate from the `pre_tool_use` policy gate.

- **argv:** `permission_request`
- **stdin:** tool request envelope
- **stdout:** durable model context
- **stderr:** durable user-only output
- **fd 3:** state, and with exit 11, `{"action":"allow"}` or `{"action":"deny","reason":"..."}`
- **Exit 0:** defer to an interactive client, or deny if none can answer
- **Exit 10:** deny and continue the hook chain
- **Exit 11:** halt the chain and apply the required decision

### `pre_tool_use`

Runs immediately before a tool.

- **argv:** `pre_tool_use`
- **stdin:** tool request envelope
- **stdout:** durable model context
- **stderr:** user-only output
- **fd 3:** state
- **Exit 0:** execute the tool
- **Exit 10:** deny the tool and continue the hook chain
- **Exit 11:** deny the tool and halt the chain

This hook can observe and gate input but cannot rewrite it or approve a sandbox bypass.

### `post_tool_use`

Runs after the tool completes but before its result is committed, including when the tool exits nonzero.

- **argv:** `post_tool_use`
- **stdin:** tool response envelope
- **stdout:** durable model context before the tool result
- **stderr:** user-only output
- **fd 3:** state
- **Exit 0:** continue the tool loop
- **Exit 10 or 11:** unsupported and fail the turn

This hook cannot replace the tool outcome. Its state and hook result are committed before the tool result.

### `stop`

Runs after a completed assistant record.

- **argv:** `stop STOP_ATTEMPT`, with a one-based attempt count
- **stdin:** text blocks from the final assistant message, concatenated in content order
- **stdout:** durable model context
- **stderr:** durable user-only output
- **fd 3:** state
- **Exit 0:** finish the turn
- **Exit 10:** commit feedback, request another provider response, and continue the hook chain
- **Exit 11:** commit feedback, request another provider response, and halt the chain

## Guarantees and limits

- Hook scripts are trusted programs, but their output remains attributed hook context rather than a human message.
- Dispatch is sequential and preserves configured order.
- Captures are private and bounded by `SHELLFISH_MAX_CAPTURE_BYTES`. Exceeding the combined budget fails the operation.
- Scripts have no independent timeout and must finish their own subprocesses.
- Cancellation terminates the active script and its ordinary descendants. Daemonizing is unsupported.
- Hooks observe and gate lifecycle operations. They do not mutate the transcript or transform tool input and results.
