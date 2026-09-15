#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh
sf_test_tmp run-tool-contract
export XDG_STATE_HOME="$tmp/state" SF_TEST_BACKEND_DELAY=0
sf_test_runtime

# Tool rendering uses the new running/user/model/permission vocabulary.
SF_TEST_RUNTIME=$(jq -c '
  .harness.tools[0].manifest.render={
    running:"${name}\n${input.command}",
    user:"${name}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}",
    model:"${output.stdout}${output.stderr}\nexit ${output.exit_code}",
    permission:"${input.command}"
  }
' <<<"$SF_TEST_RUNTIME")

# Pre-tool denial is sticky, preserves sibling calls, and still reaches post hooks.
typeset pre="$tmp/pre" later="$tmp/pre-later" post="$tmp/post"
typeset hook_dir="$tmp/hook-inputs" tool_marker="$tmp/tool-ran"
mkdir "$hook_dir"
cat >"$pre" <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
id=$(jq -r '.tool_use_id' <<<"$input")
print -rn -- "$input" >"$HOOK_DIR/pre-$id"
print -rn -u3 -- "{\"state\":[{\"name\":\"pre/$id\",\"value\":true}]}"
if [[ $id == call_1 ]]; then
  print -rn -- 'pre context'
  print -rn -u2 -- 'pre display'
  exit 10
fi
ZSH
cat >"$later" <<'ZSH'
#!/usr/bin/env zsh
id=$(jq -r '.tool_use_id')
print -r -- "$id" >>"$HOOK_DIR/later"
ZSH
cat >"$post" <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
id=$(jq -r '.tool_use_id' <<<"$input")
print -rn -- "$input" >"$HOOK_DIR/post-$id"
print -rn -u3 -- "{\"state\":[{\"name\":\"post/$id\",\"value\":true}]}"
ZSH
chmod +x "$pre" "$later" "$post"
export HOOK_DIR=$hook_dir TOOL_MARKER=$tool_marker
SF_TEST_RUNTIME=$(jq -c --arg pre "$pre" --arg later "$later" --arg post "$post" '
  .harness.pre_tool_use=[
    {command:$pre,environment:["HOOK_DIR"],running:""},
    {command:$later,environment:["HOOK_DIR"],running:""}
  ] |
  .harness.post_tool_use=[{command:$post,environment:["HOOK_DIR"],running:""}]
' <<<"$SF_TEST_RUNTIME")
typeset session="$tmp/denied.jsonl" stream="$tmp/denied.stream"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=2 \
  SF_TEST_BACKEND_TOOL_COMMAND="print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  sf_test_run tools "$session" >"$stream" || fail 'pre-tool denial turn failed'
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:$command}}' --arg command \
  "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  "$hook_dir/pre-call_1" >/dev/null || fail 'pre hook received the wrong request'
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",
  tool_input:{command:$command},tool_response:{stdout:"",stderr:"",exit_code:126}}' \
  --arg command "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  "$hook_dir/post-call_1" >/dev/null || fail 'post hook did not receive the denial outcome'
assert_equal $'call_1\ncall_2' "$(<$hook_dir/later)" \
  'status 10 did not continue pre hooks for every call'
assert_equal ran "$(<$tool_marker)" 'pre-tool denial did not preserve the sibling call'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type | IN("state","hook_result","tool_result")) |
    if .type == "state" then [.type,.name]
    elif .type == "hook_result" then [.type,.lifecycle,.exit_code]
    else [.type,.id,.exit_code] end] == [
      ["state","pre/call_1"],
      ["hook_result","pre_tool_use",10],
      ["state","post/call_1"],
      ["tool_result","call_1",126],
      ["state","pre/call_2"],
      ["state","post/call_2"],
      ["tool_result","call_2",0]
    ] and
  ($events | map(select(.type == "hook_result"))[0] |
    .model_text == "pre context" and .user_text == "pre display") and
  ($events | map(select(.type == "_tool_activity"))[1].user_text) ==
    "shell\n" + $command and
  ($events | map(select(.type == "tool_result"))[1] |
    .user_text == "shell\noutput\nexit 0" and .model_text == "output\nexit 0")
' --arg command "print -r -- ran >>${(q)tool_marker}; print -rn -- output" \
  <"$stream" >/dev/null || fail 'tool lifecycle ordering or rendering was wrong'
assert_canonical_session "$session"

# Permission hooks receive the request and may halt with allow or deny.
typeset permission="$tmp/permission" permission_input="$tmp/permission-input"
cat >"$permission" <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
print -rn -- "$input" >"$PERMISSION_INPUT"
print -rn -u3 -- '{"state":[{"name":"permission/state","value":true}],"action":"allow"}'
print -rn -- 'review context'
print -rn -u2 -- 'review display'
exit 11
ZSH
chmod +x "$permission"
export PERMISSION_INPUT=$permission_input
SF_TEST_RUNTIME=$(jq -c --arg hook "$permission" '
  .harness.pre_tool_use=[] | .harness.post_tool_use=[] |
  .harness.sandbox=true | .harness.fence="/usr/bin/true" |
  .harness.permission_request=[{command:$hook,environment:["PERMISSION_INPUT"],running:""}]
' <<<"$SF_TEST_RUNTIME")
session="$tmp/permission-allow.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  SF_TEST_BACKEND_TOOL_COMMAND='print -rn -- approved' \
  sf_test_run permission "$session" >"$stream" || fail 'permission hook allow failed'
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_1",tool_input:{
  command:"print -rn -- approved",request_sandbox_bypass:true,
  sandbox_bypass_reason:"Required by the test fixture"}}' \
  "$permission_input" >/dev/null || fail 'permission hook received the wrong request'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "_tool_permission_request") | not) and
  [$events[] | select(.type | IN("state","hook_result","tool_result")) | .type] ==
    ["state","hook_result","tool_result"] and
  ($events | map(select(.type == "hook_result"))[0] |
    .lifecycle == "permission_request" and .exit_code == 11 and
    .model_text == "review context" and .user_text == "review display") and
  ($events | map(select(.type == "tool_result"))[0].exit_code) == 0
' <"$stream" >/dev/null || fail 'permission allow produced the wrong records'

cat >"$permission" <<'ZSH'
#!/usr/bin/env zsh
cat >"$PERMISSION_INPUT"
print -rn -u3 -- '{"action":"deny","reason":"review denied"}'
exit 11
ZSH
chmod +x "$permission"
session="$tmp/permission-deny.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  sf_test_run permission "$session" >"$stream" || fail 'permission hook deny failed'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")][0] |
  .exit_code == 126 and (.model_text | contains("review denied"))
' <"$stream" >/dev/null || fail 'permission denial did not settle the call'

# No hook defers to the client; the permission exchange stays transient.
SF_TEST_RUNTIME=$(jq -c '.harness.permission_request=[]' <<<"$SF_TEST_RUNTIME")
session="$tmp/permission-client.jsonl"
sf_test_session "$session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  SF_TEST_BACKEND_TOOL_COMMAND='print -rn -- approved' \
  sf_test_run permission "$session" \
    '{"type":"_tool_permission_response","id":"permission_1","decision":"approve"}' \
    >"$stream" || fail 'client permission approval failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_tool_permission_request")) | length) == 1 and
  ($events | map(select(.type == "tool_result"))[0].exit_code) == 0
' <"$stream" >/dev/null || fail 'client permission was not requested explicitly'
jq -e -s 'all(.[]; .type != "_tool_permission_request" and
  .type != "_tool_permission_response")' "$session" >/dev/null ||
  fail 'permission exchange became durable'

# A completed failing post hook remains before the known outcome and durable error.
typeset post_fail="$tmp/post-fail"
cat >"$post_fail" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -rn -- 'post failure context'
print -rn -u2 -- 'post failure display'
exit 10
ZSH
chmod +x "$post_fail"
SF_TEST_RUNTIME=$(jq -c --arg hook "$post_fail" '
  .harness.permission_request=[] |
  .harness.post_tool_use=[{command:$hook,environment:[],running:""}]
' <<<"$SF_TEST_RUNTIME")
session="$tmp/post-failure.jsonl"
sf_test_session "$session"
integer post_status=0
SF_TEST_BACKEND_TOOL_CALL=1 sf_test_run post "$session" >"$stream" || post_status=$?
(( post_status == 1 )) || fail 'failing post hook did not fail the turn'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-3] | .type == "hook_result" and .lifecycle == "post_tool_use" and
    .exit_code == 10 and .model_text == "post failure context" and
    .user_text == "post failure display") and
  ($events[-2] | .type == "tool_result" and .id == "call_1" and .exit_code == 0) and
  ($events[-1] | .type == "error" and (.user_text | contains("post_tool_use")))
' <"$stream" >/dev/null || fail 'post failure lost or reordered the known outcome'
assert_canonical_session "$session"

print -r -- ok
