#!/usr/bin/env zsh

# The projector turns live core events and loaded durable records into one
# presentation action vocabulary. Actions are NUL-joined fields; the first is
# the action type.

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/view.zsh libexec/tui/project.zsh

typeset header=$(head -n 1 "$SF_TEST_SESSIONS/complete.jsonl")
typeset runtime=$(jq -c '.runtime | .context_window = 200' <<<"$header")

# Join one action per line for comparison; a trailing empty field shows as "|".
actions() { print -rl -- ${(@)${(@)SF_PRESENT_ACTIONS//$'\0'/ | }% } }

project() {
  local mode=$1
  shift
  sf_tui_project "$mode" "$@" || fail "the projector rejected: $*"
  REPLY=$(actions)
}

# Live deltas render once, and the durable record that follows repeats nothing.
project live \
  '{"type":"_assistant_start"}' \
  '{"type":"_assistant_message_delta","index":0,"text":"I will look."}' \
  '{"type":"_assistant_reasoning_delta","index":1,"text":"weighing"}' \
  '{"type":"_assistant_end","stop":"end"}' \
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"I will look."},{"type":"reasoning","text":"weighing"}],"usage":{"input_tokens":2,"output_tokens":1}}'
assert_equal 'message_start | agent
message_delta | 0 | text | I will look. |
message_delta | 1 | reasoning | weighing |
message_end
usage | 2 ↑ 1 ↓ |' "$REPLY"

# A loaded durable response produces the same ordered message actions.
project load \
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"I will look."},{"type":"reasoning","text":"weighing"}],"usage":{"input_tokens":2,"output_tokens":1,"reasoning_tokens":40}}'
assert_equal 'message_start | agent
message_delta | 0 | text | I will look. |
message_delta | 1 | reasoning | weighing | 40
message_end
usage | 2 ↑ 1 ↓ | 40' "$REPLY"

# Loaded prompts and system text become messages; live ones are already shown.
project load \
  '{"type":"user","content":[{"type":"text","text":"Hello"}]}' \
  '{"type":"system","content":"be brief"}'
assert_equal 'message_start | user
message_delta | 0 | text | Hello |
message_end
message_start | system
message_delta | 0 | text | be brief |
message_end' "$REPLY"
project live \
  '{"type":"user","content":[{"type":"text","text":"Hello"}]}' \
  '{"type":"system","content":"be brief"}'
assert_equal '' "$REPLY"

# Tool calls update one execution and settle it with their own preview hints.
project live \
  '{"type":"_draft","id":"call_1","name":"shell","user_text":"shell · make test","user_preview_lines":2}' \
  '{"type":"tool_result","id":"call_1","name":"shell","input":{"command":"make test"},"exit_code":0,"user_text":"shell · make test\nok","model_text":"ok","user_preview_lines":"full"}'
assert_equal 'execution_update | call_1 | shell | tool | shell · make test | 2
execution_end | call_1 | shell | tool | shell · make test
ok | full' "$REPLY"

# Hook context is reference material; a hook notice speaks only to the reader.
# Drafts and results carry their own preview hints.
project live \
  '{"type":"_draft","lifecycle":"pre_tool_use","id":"1","user_text":"guard · checking","user_preview_lines":1}' \
  '{"type":"_draft","lifecycle":"pre_tool_use","id":"1","user_text":""}' \
  '{"type":"hook_result","lifecycle":"pre_tool_use","id":"1","user_text":"guard · ok","user_preview_lines":"full"}' \
  '{"type":"hook_result","lifecycle":"session_start","id":"2","user_text":"project · read","model_text":"context"}' \
  '{"type":"hook_result","lifecycle":"session_start","id":"3","model_text":"Git branch: main"}'
assert_equal 'execution_update | 1 |  | notice | guard · checking | 1
execution_end | 1 |  | notice |  | default
execution_end | 1 |  | notice | guard · ok | full
execution_end | 2 |  | context | project · read | default
execution_end | 3 |  | context | session_start | default' "$REPLY"

# Permissions carry the preview the client displays.
project live \
  '{"type":"_tool_permission_request","id":"permission_1","tool":{"name":"shell","input":{"command":"git status"}},"reason":"writes outside the sandbox","preview":"git status"}'
assert_equal \
  'permission | permission_1 | shell | git status | writes outside the sandbox' \
  "$REPLY"

# Errors split their heading from the detail below it.
project live '{"type":"error","user_text":"Cancelled.\nstopped by the user"}'
assert_equal 'error | Cancelled. | stopped by the user' "$REPLY"

# The header and later updates carry runtime identity; usage reads its window.
project load "$header"
assert_equal 'runtime | test/fake-model |' "$REPLY"
project live "$(jq -cn --argjson runtime "$runtime" \
  '{type:"_session_update",runtime:$runtime}')"
assert_equal 'runtime | test/fake-model | 200' "$REPLY"
project live \
  '{"type":"assistant","stop":"end","content":[],"usage":{"input_tokens":75,"cached_tokens":15,"output_tokens":5}}'
assert_equal 'usage | 75 ↑ 20% ⦿ 5 ↓ 38% of 200 ◔ |' "$REPLY"

# The loaded path event names the session the client now owns.
project load '{"type":"_session_load","path":"/sessions/live.jsonl"}'
assert_equal 'session | /sessions/live.jsonl' "$REPLY"

# A handoff carries its argument vector.
project live '{"type":"_handoff","argv":["shellfish","--clear"]}'
assert_equal 'handoff | shellfish | --clear' "$REPLY"

# Tool-call and opaque blocks carry ordering only, live or loaded, so the
# renderer can close the block before them.
project live \
  '{"type":"_assistant_tool_call_delta","index":2}' \
  '{"type":"_assistant_reasoning_opaque","index":3}'
assert_equal 'message_delta | 2 | inert |  |
message_delta | 3 | inert |  |' "$REPLY"
project load \
  '{"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"running"},{"type":"tool_call","id":"call_1","name":"shell","input":{"command":"pwd"}}]}'
assert_equal 'message_start | agent
message_delta | 0 | text | running |
message_delta | 1 | inert |  |
message_end' "$REPLY"

# Model-only events present nothing.
project live \
  '{"type":"_turn_usage","usage":{"input_tokens":1,"output_tokens":1}}' \
  '{"type":"state","name":"probe","value":true}'
assert_equal '' "$REPLY"

# An unsupported or malformed line rejects the whole batch.
integer project_status=0
sf_tui_project live '{"type":"_assistant_message_delta","index":0,"text":"partial"}' \
  '{"type":"_unknown"}' || project_status=$?
assert_equal 1 "$project_status"
assert_equal 0 "${#SF_PRESENT_ACTIONS}"
project_status=0
sf_tui_project live 'not json' || project_status=$?
assert_equal 1 "$project_status"
assert_equal 0 "${#SF_PRESENT_ACTIONS}"

print -r -- ok
