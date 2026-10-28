#!/usr/bin/env zsh

# The projector turns live core events and loaded durable records into one
# presentation action vocabulary. Actions are NUL-joined fields; the first is
# the action type.

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/view.zsh libexec/tui/project.zsh

typeset header=$(head -n 1 "$SF_TEST_SESSIONS/complete.jsonl")
typeset update=$(jq -c '{type:"_session_update",profile,model:(.model | .context_window = 200)}' \
  <<<"$header")

# Join one action per line for comparison; a trailing empty field shows as "|".
actions() { print -rl -- ${(@)${(@)SF_PRESENT_ACTIONS//$'\0'/ | }% } }

project() {
  local mode=$1
  shift
  sf_tui_project "$mode" "$@" || fail "the projector rejected: $*"
  REPLY=$(actions)
}

# Live previews render once, and the durable record that follows closes them.
project live \
  '{"type":"_assistant_start"}' \
  '{"type":"_assistant_message_delta","text":"I will look."}' \
  '{"type":"_assistant_reasoning_delta","text":"weighing"}' \
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"I will look."},{"type":"reasoning","text":"weighing"}],"usage":{"input_tokens":2,"output_tokens":1}}'
assert_equal 'message_start | agent
message_delta | 0 | text | I will look. |
message_delta | 0 | reasoning | weighing |
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

# User records render in both modes; the header's system text only on replay.
typeset briefed=$(jq -c '.profile.system = [{text:"be brief"}]' <<<"$header")
project load "$briefed" '{"type":"user","content":[{"type":"text","text":"Hello"}]}'
assert_equal 'profile | test/fake-model |
message_start | system
message_delta | 0 | text | be brief |
message_end
message_start | user
message_delta | 0 | text | Hello |
message_end' "$REPLY"
project live "$briefed" '{"type":"user","content":[{"type":"text","text":"Hello"}]}'
assert_equal 'profile | test/fake-model |
message_start | user
message_delta | 0 | text | Hello |
message_end' "$REPLY"

# Tool calls update one execution and settle it with their own preview hints.
project live \
  '{"type":"_draft","id":"call_1","name":"shell","user_text":"shell · make test","user_preview_lines":2}' \
  '{"type":"tool_result","id":"call_1","name":"shell","input":{"command":"make test"},"exit_code":0,"user_text":"shell · make test\nok","model_text":"ok","user_preview_lines":"full"}'
assert_equal 'execution_update | call_1 | tool | shell · make test | 2
execution_end | call_1 | tool | shell · make test
ok | full' "$REPLY"

# No template can hide an approved sandbox bypass.
project live \
  '{"type":"_draft","id":"call_2","name":"shell","sandbox_bypassed":true}' \
  '{"type":"tool_result","id":"call_2","name":"shell","input":{},"exit_code":0,"sandbox_bypassed":true}'
assert_equal 'execution_update | call_2 | tool | [unsandboxed] shell | default
execution_end | call_2 | tool | [unsandboxed] shell | default' "$REPLY"
project load \
  '{"type":"tool_result","id":"call_2","name":"shell","input":{},"exit_code":0,"sandbox_bypassed":true}'
assert_equal 'execution_end | call_2 | tool | [unsandboxed] shell | default' "$REPLY"

# Normal tool execution carries no bypass badge.
project live \
  '{"type":"_draft","id":"call_3","name":"skill","user_text":"Skill code-principles"}' \
  '{"type":"tool_result","id":"call_3","name":"skill","input":{"name":"code-principles"},"exit_code":0,"user_text":"Skill code-principles"}'
assert_equal 'execution_update | call_3 | tool | Skill code-principles | default
execution_end | call_3 | tool | Skill code-principles | default' "$REPLY"

# Hook context is reference material; a hook notice speaks only to the reader.
# Drafts and results carry their own preview hints.
project live \
  '{"type":"_draft","lifecycle":"pre_tool_use","id":"1","user_text":"guard · checking","user_preview_lines":1}' \
  '{"type":"hook_result","lifecycle":"pre_tool_use","id":"1","user_text":"guard · ok","user_preview_lines":"full"}' \
  '{"type":"hook_result","lifecycle":"session_start","id":"2","user_text":"project · read","model_text":"context"}' \
  '{"type":"hook_result","lifecycle":"session_start","id":"3","model_text":"Git branch: main"}'
assert_equal 'execution_update | 1 | notice | guard · checking | 1
execution_end | 1 | notice | guard · ok | full | agent
execution_end | 2 | context | project · read | default | system
execution_end | 3 | context |  | default | system' "$REPLY"

# Hook headings follow their lifecycle, live or on replay.
project load \
  '{"type":"hook_result","lifecycle":"session_start","id":"1","model_text":"start"}' \
  '{"type":"hook_result","lifecycle":"user_prompt_submit","id":"2","model_text":"prompt"}' \
  '{"type":"hook_result","lifecycle":"pre_tool_use","id":"3","model_text":"before"}' \
  '{"type":"hook_result","lifecycle":"stop","id":"4","model_text":"later"}'
assert_equal 'execution_end | 1 | context |  | default | system
execution_end | 2 | context |  | default | user
execution_end | 3 | context |  | default | agent
execution_end | 4 | context |  | default | agent' "$REPLY"
project load \
  '{"type":"hook_result","lifecycle":"session_start","id":"5","user_text":"startup notice"}'
assert_equal 'execution_end | 5 | notice | startup notice | default | system' "$REPLY"

# Permissions show the tool name and its raw input.
project live \
  '{"type":"_tool_permission_request","id":"permission_1","tool":{"name":"shell","input":{"command":"git status"}},"reason":"writes outside the sandbox"}'
assert_equal \
  'permission | permission_1 | shell | {"command":"git status"} | writes outside the sandbox' \
  "$REPLY"

# Errors split their heading from the detail below it.
project live '{"type":"error","user_text":"Cancelled.\nstopped by the user"}'
assert_equal 'error | Cancelled. | stopped by the user' "$REPLY"

# The header and later updates carry model identity; usage reads its window.
project load "$header"
assert_equal 'profile | test/fake-model |' "$REPLY"
project live "$update"
assert_equal 'profile | test/fake-model | 200' "$REPLY"
project live \
  '{"type":"assistant","stop":"end","content":[],"usage":{"input_tokens":75,"cached_tokens":15,"output_tokens":5}}'
assert_equal 'message_end
usage | 75 ↑ 20% ⦿ 5 ↓ 38% of 200 ◔ |' "$REPLY"

# The loaded path event names the session the client now owns.
project load '{"type":"_session_load","path":"/sessions/live.jsonl"}'
assert_equal 'session | /sessions/live.jsonl' "$REPLY"

# A handoff carries its argument vector.
project live '{"type":"_handoff","argv":["shellfish","--clear"]}'
assert_equal 'handoff | shellfish | --clear' "$REPLY"

# A loaded tool call carries ordering only, so the renderer can close the
# block before it.
project load \
  '{"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"running"},{"type":"tool_call","id":"call_1","name":"shell","input":{"command":"pwd"}}]}'
assert_equal 'message_start | agent
message_delta | 0 | text | running |
message_delta | 1 | inert |  |
message_end' "$REPLY"

# Model-only records present nothing.
project live '{"type":"state_update","name":"probe","value":true}'
assert_equal '' "$REPLY"

# An unsupported or malformed line rejects the whole batch.
integer project_status=0
sf_tui_project live '{"type":"_assistant_message_delta","text":"partial"}' \
  '{"type":"_unknown"}' || project_status=$?
assert_equal 1 "$project_status"
assert_equal 0 "${#SF_PRESENT_ACTIONS}"
project_status=0
sf_tui_project live 'not json' || project_status=$?
assert_equal 1 "$project_status"
assert_equal 0 "${#SF_PRESENT_ACTIONS}"

print -r -- ok
