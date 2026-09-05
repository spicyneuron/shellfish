#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp exec-command-permission

typeset config="$tmp/shellfish.jsonc"
cat >"$config" <<EOF
{
  "default_profile": "exec",
  "backends": {"fixture": {"adapter": "$ROOT/tests/fixtures/backend"}},
  "harnesses": {
    "machine": {
      "tools": ["shell"], "sandbox": true,
      "session_start": [], "user_prompt_submit": [], "permission_request": [],
      "pre_tool_use": [], "post_tool_use": [], "stop": [],
      "max_requests_per_turn": 8, "max_tool_calls_per_request": 16,
      "max_capture_bytes": 65536
    }
  },
  "profiles": {
    "exec": {
      "backend": "fixture", "harness": "machine",
      "request": {"model": "test-model"}
    }
  }
}
EOF
export XDG_STATE_HOME="$tmp/state"
typeset entry="$ROOT/bin/shellfish"

# JSON input accepts only the active permission response after its user record.
# The response is transient, while the resulting tool record remains durable.
typeset session="$tmp/permission.jsonl"
typeset output="$tmp/permission.out"
printf '%s\n' \
  '{"type":"message","role":"user","content":[{"type":"text","text":"approve bounded"}]}' \
  '{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}' |
  SF_TEST_BACKEND_DELAY=0 SF_TEST_BACKEND_TOOL_CALL=1 \
    SF_TEST_BACKEND_TOOL_BYPASS=true SF_TEST_BACKEND_TOOL_COMMAND='printf approved' \
    zsh -f "$entry" run --jsonl --config "$config" \
      --session "$session" >"$output" || fail 'bounded permission approval failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request"))) ==
    [{type:"_tool_permission_request",id:"permission_1",reason:"Required by the test fixture",
      tool:{call_id:"call_1",name:"shell",
        input:{command:"printf approved",request_sandbox_bypass:true,
          sandbox_bypass_reason:"Required by the test fixture"}}}] and
  ($events | map(select(.role == "tool_result"))[0] |
    .exit_code == 0 and .content == "approved")
' <"$output" >/dev/null || fail 'bounded approval was not applied'
jq -se 'all(.[]; .type != "_tool_permission_response" and
  .type != "_tool_permission_request")' "$session" >/dev/null ||
  fail 'transient permission traffic entered the session'

typeset denied_session="$tmp/denied-permission.jsonl"
printf '%s\n' \
  '{"type":"message","role":"user","content":[{"type":"text","text":"deny bounded"}]}' \
  '{"type":"_tool_permission_response","id":"permission_1","decision":"deny"}' |
  SF_TEST_BACKEND_DELAY=0 SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
    zsh -f "$entry" run --jsonl --config "$config" \
      --session "$denied_session" >"$tmp/denied-permission.out" ||
  fail 'bounded permission denial failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "tool_result"))[0] |
    .exit_code == 126 and .content == "sandbox bypass denied")
' <"$tmp/denied-permission.out" >/dev/null || fail 'bounded denial was not applied'

typeset wrong_session="$tmp/wrong-permission.jsonl"
typeset wrong_output="$tmp/wrong-permission.out"
printf '%s\n' \
  '{"type":"message","role":"user","content":[{"type":"text","text":"wrong permission"}]}' \
  '{"type":"_tool_permission_response","id":"permission_2","decision":"approve"}' |
  SF_TEST_BACKEND_DELAY=0 SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
    zsh -f "$entry" run --jsonl --config "$config" \
      --session "$wrong_session" >"$wrong_output" &&
  fail 'bounded invalid permission response exited successfully'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "_turn_error" and .message == "invalid permission response")) and
  ($events | map(select(.role == "tool_result"))[0].exit_code) == 126 and
  $events[-2].role == "assistant" and $events[-2].stop == "end"
' <"$wrong_output" >/dev/null || fail 'bounded permission accepted the wrong request identity'

typeset eof_session="$tmp/permission-eof.jsonl"
print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"permission eof"}]}' |
  SF_TEST_BACKEND_DELAY=0 SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
    zsh -f "$entry" run --jsonl --config "$config" \
      --session "$eof_session" >"$tmp/permission-eof.out" ||
  fail 'permission EOF denial failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "_turn_error") | not) and
  ($events | map(select(.role == "tool_result"))[0].exit_code) == 126
' <"$tmp/permission-eof.out" >/dev/null || fail 'permission EOF did not close the active turn'

# Tool projection is frozen runtime data, so plain and JSONL exec send identical tools.
typeset projection_session="$tmp/projection.jsonl"
typeset request_capture="$tmp/request.json"
print -r -- 'projected plainly' |
  SF_TEST_BACKEND_DELAY=0 SF_TEST_BACKEND_REQUEST="$request_capture" \
    zsh -f "$entry" run --config "$config" --session "$projection_session" \
      >/dev/null || fail 'plain projection turn failed'
typeset plain_tools=$(jq -c '.tools' "$request_capture")
print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"projected as jsonl"}]}' |
  SF_TEST_BACKEND_DELAY=0 SF_TEST_BACKEND_REQUEST="$request_capture" \
    zsh -f "$entry" run --jsonl --config "$config" --session "$projection_session" \
      >/dev/null || fail 'jsonl projection turn failed'
assert_equal "$plain_tools" "$(jq -c '.tools' "$request_capture")"
