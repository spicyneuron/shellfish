#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh

sf_test_tmp exec-tool-cancel
export XDG_STATE_HOME="$tmp/state"
sf_test_runtime
export SF_TEST_BACKEND_DELAY=0

# Cancelling an executing tool terminates its process group and uses ordinary
# turn recovery.
typeset cancel_session="$tmp/tool-cancel.jsonl"
typeset cancel_stream="$tmp/tool-cancel.stream"
typeset marker="$tmp/tool-active" exit_marker="$tmp/tool-exit"
typeset command=": >${(q)marker}; sleep 5; : >${(q)exit_marker}"
sf_test_session "$cancel_session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND="$command" \
  "$ROOT/bin/shellfish" run --jsonl --session "$cancel_session" \
    < <(print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"cancel tool"}]}') \
    >"$cancel_stream" &
integer pid=$! cancel_status=0 waited=0
while (( waited++ < 50 )) && [[ ! -e $marker ]]; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'tool did not start'
kill -TERM "$pid"
wait "$pid" || cancel_status=$?
(( cancel_status == 143 )) || fail 'cancelled tool exec returned the wrong status'
[[ ! -e $exit_marker ]] || fail 'cancelled tool ran to completion'
print -r -- "$(<"$cancel_stream")" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "tool_result"))) == [{
    type:"message",role:"tool_result",call_id:"call_1",name:"shell",
    content:"tool call interrupted",exit_code:126
  }] and $events[-1] == {type:"turn_error",message:"Turn interrupted."}
' >/dev/null
assert_canonical_session "$cancel_session"

# Cancellation escalates when a tool ignores TERM instead of hanging indefinitely.
typeset stubborn_session="$tmp/tool-stubborn.jsonl"
typeset stubborn_stream="$tmp/tool-stubborn.stream"
typeset stubborn_marker="$tmp/tool-stubborn-active"
typeset stubborn_command="trap '' TERM; : >${(q)stubborn_marker}; while :; do sleep 1; done"
sf_test_session "$stubborn_session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND="$stubborn_command" \
  "$ROOT/bin/shellfish" run --jsonl --session "$stubborn_session" \
    < <(print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"cancel stubborn tool"}]}') \
    >"$stubborn_stream" &
integer stubborn_pid=$! stubborn_status=0
waited=0
while (( waited++ < 50 )) && [[ ! -e $stubborn_marker ]]; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'stubborn tool did not start'
kill -TERM "$stubborn_pid"
wait "$stubborn_pid" || stubborn_status=$?
(( stubborn_status == 143 )) || fail 'cancelled stubborn exec returned the wrong status'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "tool_result") | .exit_code)) == [126] and
  $events[-1] == {type:"turn_error",message:"Turn interrupted."}
' <"$stubborn_stream" >/dev/null

# State written before cancellation is discarded because the tool did not
# complete normally.
typeset state_tool="$tmp/state-tool" state_session="$tmp/tool-state.jsonl"
typeset state_stream="$tmp/tool-state.stream" state_marker="$tmp/tool-state-active"
cat >"$state_tool" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -rn -u3 -- '{"state":[{"name":"tools/cancelled","value":true}]}'
: >"$STATE_MARKER"
trap 'exit 143' TERM
while true; do sleep 1; done
ZSH
chmod +x "$state_tool"
SF_TEST_RUNTIME=$(jq -c --arg command "$state_tool" '
  .harness.tools[0].command=$command |
  .harness.tools[0].manifest.environment=["STATE_MARKER"]
' <<<"$SF_TEST_RUNTIME") || fail 'cannot prepare cancelled tool state runtime'
sf_test_session "$state_session"
STATE_MARKER="$state_marker" SF_TEST_BACKEND_TOOL_CALL=1 \
  "$ROOT/bin/shellfish" run --jsonl --session "$state_session" \
    < <(print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"cancel state tool"}]}') \
    >"$state_stream" &
pid=$!
cancel_status=0
waited=0
while (( waited++ < 50 )) && [[ ! -e $state_marker ]]; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'state tool did not start'
kill -TERM "$pid"
wait "$pid" || cancel_status=$?
(( cancel_status == 143 )) || fail 'cancelled state tool returned the wrong status'
jq -eRn '[inputs | fromjson] | all(.type != "state")' <"$state_stream" >/dev/null ||
  fail 'cancelled tool state was emitted'
jq -e -s 'all(.type != "state")' "$state_session" >/dev/null ||
  fail 'cancelled tool state became durable'
