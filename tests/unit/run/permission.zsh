#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh lib/hooks.zsh

typeset stream
sf_test_tmp exec-permission
export XDG_STATE_HOME="$tmp/state"
typeset system_file="$tmp/system.md"
typeset request_capture="$tmp/request.json"
printf 'frozen system\n' >"$system_file"

sf_test_runtime "$system_file"
export SF_TEST_BACKEND_DELAY=0
export SF_TEST_BACKEND_REQUEST="$request_capture"

# A configured permission_request script exposes bypass approval without an interactive
# adapter. Its decision precedes the existing UI path and its stderr stays local.
typeset permission_allow="$tmp/permission-allow"
cat >"$permission_allow" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 1 && $1 == permission_request ]]
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:"printf headless",request_sandbox_bypass:true,
    sandbox_bypass_reason:"Required by the test fixture"}}' >/dev/null
print -rn -- ignored
print -rn -u2 -- reviewed
print -rn -u3 -- '{"action":"allow"}'
exit 11
ZSH
chmod +x "$permission_allow"
SF_TEST_RUNTIME=$(jq -c --arg hook "$permission_allow" '
  .harness.sandbox=true | .harness.permission_request=[$hook]
' <<<"$SF_TEST_RUNTIME")
typeset permission_allow_session="$tmp/permission-allow.jsonl"
sf_test_session "$permission_allow_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  SF_TEST_BACKEND_TOOL_COMMAND='printf headless' \
  sf_test_turn 'review headlessly' "$permission_allow_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 0 and
  ($events | map(select(.type == "_hook_display" and .complete) | [.hook,(.script|split("/")[-1]),.text])) ==
    [["permission_request","permission-allow","reviewed"]] and
  ($events | map(select(.role == "tool_result"))[0] |
    .exit_code == 0 and .content == "headless")
' >/dev/null
jq -e '
  .tools[0].input_schema.properties.request_sandbox_bypass.type == "boolean" and
  (.tools[0].input_schema.properties.request_sandbox_bypass.description |
    contains("interactive") | not)
' "$request_capture" >/dev/null
# Tool projection comes only from frozen runtime, so every client sees these tools.
typeset frozen_tools=$(jq -c '.tools' "$request_capture")
jq -e -s 'all(.[]; .type != "context")' "$permission_allow_session" >/dev/null

# A script denial uses its reason without consulting the UI. With no configured
# permission_request script and no UI, exec denies a bypass request.
typeset permission_deny="$tmp/permission-deny"
cat >"$permission_deny" <<'ZSH'
#!/usr/bin/env zsh
print -rn -u3 -- '{"action":"deny","reason":"risk too high"}'
exit 11
ZSH
chmod +x "$permission_deny"
SF_TEST_RUNTIME=$(jq -c --arg hook "$permission_deny" \
  '.harness.permission_request=[$hook]' <<<"$SF_TEST_RUNTIME")
typeset permission_deny_session="$tmp/permission-deny.jsonl"
sf_test_session "$permission_deny_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  sf_test_turn 'deny headlessly' "$permission_deny_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "tool_result"))[0] |
    .exit_code == 126 and .content == "risk too high")
' >/dev/null

SF_TEST_RUNTIME=$(jq 'del(.harness.permission_request)' \
  <<<"$SF_TEST_RUNTIME")
typeset permission_fallback_session="$tmp/permission-fallback.jsonl"
sf_test_session "$permission_fallback_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  sf_test_turn 'deny without adapter' "$permission_fallback_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 0 and
  ($events | map(select(.role == "tool_result"))[0] |
    .exit_code == 126 and .content == "sandbox bypass denied")
' >/dev/null
assert_equal "$frozen_tools" "$(jq -c '.tools' "$request_capture")"

# A reply channel advertises bypass and applies the next stdin line. Approve
# executes; deny uses the fallback reason; a malformed reply or a closed channel
# fails the turn rather than silently becoming denial.
typeset permission_approve_session="$tmp/permission-approve.jsonl"
sf_test_session "$permission_approve_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  SF_TEST_BACKEND_TOOL_COMMAND='printf approved' \
  sf_test_turn 'approve via reply' "$permission_approve_session" 1 \
  '{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}')
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request"))) ==
    [{type:"_tool_permission_request",id:"permission_1",reason:"Required by the test fixture",
      tool:{call_id:"call_1",name:"shell",
        input:{command:"printf approved",request_sandbox_bypass:true,
          sandbox_bypass_reason:"Required by the test fixture"}}}] and
  ($events | map(select(.role == "tool_result"))[0] |
    .exit_code == 0 and .content == "approved")
' >/dev/null
assert_equal "$frozen_tools" "$(jq -c '.tools' "$request_capture")"

typeset permission_reply_deny_session="$tmp/permission-reply-deny.jsonl"
sf_test_session "$permission_reply_deny_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  sf_test_turn 'deny via reply' "$permission_reply_deny_session" 1 \
  '{"type":"_tool_permission_response","id":"permission_1","decision":"deny"}')
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 1 and
  ($events | map(select(.role == "tool_result"))[0] |
    .exit_code == 126 and .content == "sandbox bypass denied")
' >/dev/null

typeset permission_invalid_reply_session="$tmp/permission-invalid-reply.jsonl"
sf_test_session "$permission_invalid_reply_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  sf_test_turn 'reject a hook-shaped reply' "$permission_invalid_reply_session" 1 \
  '{"type":"_tool_permission_response","id":"permission_1","decision":"allow"}')
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 1 and
  ($events | map(select(.role == "tool_result"))[0] |
    .exit_code == 126 and .content == "tool call interrupted") and
  ($events | map(select(.type == "_turn_error") | .message) |
    any(. == "invalid permission response"))
' >/dev/null
jq -L "$ROOT" -e -s '
  include "lib/runtime/schema";
  (.[1:] | canonical_session_records) and .[-1].stop == "end"
' "$permission_invalid_reply_session" >/dev/null

typeset permission_eof_session="$tmp/permission-eof.jsonl"
sf_test_session "$permission_eof_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  sf_test_turn 'close the reply channel' "$permission_eof_session" 1)
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 1 and
  ($events | map(select(.role == "tool_result"))[0].exit_code) == 126 and
  ($events | any(.type == "_turn_error") | not)
' >/dev/null
jq -L "$ROOT" -e -s '
  include "lib/runtime/schema";
  (.[1:] | canonical_session_records) and .[-1].stop == "end"
' "$permission_eof_session" >/dev/null

# Cancellation while awaiting a frontend decision closes every pending durable
# tool call canonically and does not leave the session or reply channel owned.
typeset permission_cancel_session="$tmp/permission-cancel.jsonl"
typeset permission_cancel_stream="$tmp/permission-cancel.stream"
typeset permission_cancel_fifo="$tmp/permission-cancel.fifo"
sf_test_session "$permission_cancel_session"
mkfifo "$permission_cancel_fifo"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  SF_TEST_BACKEND_TOOL_COUNT=3 \
  "$ROOT/bin/shellfish" run --jsonl --session "$permission_cancel_session" \
    <"$permission_cancel_fifo" >"$permission_cancel_stream" &
integer permission_cancel_pid=$! permission_cancel_status=0 waited=0
exec {permission_cancel_fd}>"$permission_cancel_fifo"
jq -cn '{type:"message",role:"user",content:[{type:"text",text:"cancel permission"}]}' \
  >&$permission_cancel_fd
while (( waited++ < 50 )) &&
    ! grep -q '"_tool_permission_request"' "$permission_cancel_stream" 2>/dev/null; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'permission request was not emitted'
kill -TERM "$permission_cancel_pid"
wait "$permission_cancel_pid" || permission_cancel_status=$?
exec {permission_cancel_fd}>&-
(( permission_cancel_status == 143 )) ||
  fail 'cancelled permission exec returned the wrong status'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 1 and
  ($events | map(select(.role == "tool_result") |
    [.call_id, .exit_code])) ==
    [["call_1",126],["call_2",126],["call_3",126]] and
  $events[-1].role == "assistant" and $events[-1].stop == "end"
' <"$permission_cancel_stream" >/dev/null
jq -L "$ROOT" -e -s '
  include "lib/runtime/schema";
  (.[1:] | canonical_session_records) and .[-1].stop == "end"
' "$permission_cancel_session" >/dev/null

# Malformed hook control fails the turn rather than silently becoming denial.
typeset permission_invalid="$tmp/permission-invalid"
cat >"$permission_invalid" <<'ZSH'
#!/usr/bin/env zsh
print -rn -u3 -- '{"action":"allow","extra":true}'
exit 11
ZSH
chmod +x "$permission_invalid"
SF_TEST_RUNTIME=$(jq -c --arg hook "$permission_invalid" \
  '.harness.permission_request=[$hook]' <<<"$SF_TEST_RUNTIME")
typeset permission_invalid_session="$tmp/permission-invalid.jsonl"
sf_test_session "$permission_invalid_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  sf_test_turn 'invalid review' "$permission_invalid_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_turn_error") | .message) |
    any(. == "permission_request hook script returned invalid decision"))
' >/dev/null
