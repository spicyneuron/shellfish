#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-tool-cancel-contract
export XDG_STATE_HOME="$tmp/state" SF_TEST_BACKEND_DELAY=0
sf_test_runtime
SF_TEST_RUNTIME=$(jq -c '
  .harness.tools[0].manifest.render={
    initial_user_text:"${name}\n${input.command}",
    user_text:"${name}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}",
    model_text:"${output.stdout}${output.stderr}\nexit ${output.exit_code}",
    permission_user_text:"${input.command}"
  }
' <<<"$SF_TEST_RUNTIME")

# Interrupting an active tool settles it and cancels later calls from the
# already-durable assistant response without starting more lifecycle hooks.
typeset session="$tmp/tool-cancel.jsonl" stream="$tmp/tool-cancel.stream"
typeset marker="$tmp/tool-active" finished="$tmp/tool-finished"
typeset command=": >${(q)marker}; sleep 30; : >${(q)finished}"
sf_test_session "$session"
jq -cn --arg text cancel '{type:"user",content:[{type:"text",text:$text}]}' |
  SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=2 \
  SF_TEST_BACKEND_TOOL_COMMAND="$command" \
  "$ROOT/bin/shellfish" run --jsonl --session "$session" >"$stream" &
integer pid=$! waited=0 run_status=0
while (( waited++ < 100 )) && [[ ! -e $marker ]]; do sleep 0.02; done
(( waited <= 100 )) || fail 'active tool did not start'
kill -TERM "$pid" || fail 'tool turn ended before interruption'
wait "$pid" || run_status=$?
(( run_status == 143 )) || fail 'interrupted tool turn returned the wrong status'
[[ ! -e $finished ]] || fail 'interrupted tool ran to completion'
jq -eRn --arg command "$command" '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "tool_result") |
    {id,input,exit_code,model_text})) == [
      {id:"call_1",input:{command:$command},exit_code:126,
       model_text:"tool call interrupted\nexit 126"},
      {id:"call_2",input:{command:$command},exit_code:126,
       model_text:"tool call cancelled\nexit 126"}
    ] and
  $events[-1] == {type:"error",user_text:"Turn interrupted."}
' <"$stream" >/dev/null || fail 'tool interruption did not settle pending calls'
assert_canonical_session "$session"

# Opening a session whose turn never finished settles its calls the same way.
typeset recovered="$tmp/recovered.jsonl" recovered_stream="$tmp/recovered.stream"
sf_test_session "$recovered"
jq -cn '{type:"user",content:[{type:"text",text:"interrupted"}]}' >>"$recovered"
jq -cn '{type:"assistant",stop:"tool_calls",
  content:[{type:"tool_call",id:"call_1",name:"shell",input:{command:"true"}}]}' >>"$recovered"
jq -cn '{type:"user",content:[{type:"text",text:"next"}]}' |
  "$ROOT/bin/shellfish" run --jsonl --session "$recovered" >"$recovered_stream" ||
  fail 'recovery run failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[0] | .type == "tool_result" and .id == "call_1" and .exit_code == 126 and
    (has("executable") | not) and .model_text == "tool call outcome unknown\nexit 126") and
  ($events[1] == {type:"error",user_text:"Turn interrupted."})
' <"$recovered_stream" >/dev/null || fail 'recovery did not settle through the tool owner'
assert_canonical_session "$recovered"

print -r -- ok
