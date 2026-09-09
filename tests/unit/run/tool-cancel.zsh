#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh

sf_test_tmp exec-tool-cancel
export XDG_STATE_HOME="$tmp/state"
sf_test_runtime
export SF_TEST_BACKEND_DELAY=0

# Cancelling an executing tool signals its process group and uses ordinary turn
# recovery.
typeset cancel_session="$tmp/tool-cancel.jsonl"
typeset cancel_stream="$tmp/tool-cancel.stream"
typeset marker="$tmp/tool-active" exit_marker="$tmp/tool-exit"
typeset command=": >${(q)marker}; sleep 5; : >${(q)exit_marker}"
sf_test_session "$cancel_session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND="$command" \
  "$ROOT/bin/shellfish" run --jsonl --session "$cancel_session" \
    < <(print -r -- '{"type":"user","content":[{"type":"text","text":"cancel tool"}]}') \
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
  ($events | map(select(.type == "tool_result"))) == [{
    type:"tool_result",call_id:"call_1",name:"shell",
    content:"tool call interrupted",exit_code:126
  }] and $events[-1] == {type:"turn_error",message:"Turn interrupted."}
' >/dev/null
assert_canonical_session "$cancel_session"

# Descendants share the isolated group even when the command creates more than
# one generation of processes.
typeset tree_session="$tmp/tool-tree.jsonl" tree_stream="$tmp/tool-tree.stream"
typeset tree_marker="$tmp/tool-tree-active" tree_pid_file="$tmp/tool-tree-pid"
typeset tree_command="(sleep 30 & print -r -- \\$! >${(q)tree_pid_file}; wait) & : >${(q)tree_marker}; wait"
sf_test_session "$tree_session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND="$tree_command" \
  "$ROOT/bin/shellfish" run --jsonl --session "$tree_session" \
    < <(print -r -- '{"type":"user","content":[{"type":"text","text":"cancel tree"}]}') \
    >"$tree_stream" &
pid=$!
cancel_status=0
waited=0
while (( waited++ < 50 )) && [[ ! -s $tree_pid_file ]]; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'tool grandchild did not start'
integer tree_pid tree_polls=0
tree_pid=$(<"$tree_pid_file")
kill -TERM "$pid"
wait "$pid" || cancel_status=$?
(( cancel_status == 143 )) || fail 'cancelled tree exec returned the wrong status'
while (( tree_polls++ < 50 )) && kill -0 "$tree_pid" 2>/dev/null; do sleep 0.01; done
! kill -0 "$tree_pid" 2>/dev/null || fail 'cancelled tool grandchild survived'

# Cancellation escalates to KILL, and a command that ignores TERM and keeps the
# capture pipes open cannot hold the turn open with it.
typeset stubborn_session="$tmp/tool-stubborn.jsonl"
typeset stubborn_stream="$tmp/tool-stubborn.stream"
typeset stubborn_marker="$tmp/tool-stubborn-active"
typeset stubborn_command="trap '' TERM; : >${(q)stubborn_marker}; while :; do sleep 1; done"
sf_test_session "$stubborn_session"
SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND="$stubborn_command" \
  "$ROOT/bin/shellfish" run --jsonl --session "$stubborn_session" \
    < <(print -r -- '{"type":"user","content":[{"type":"text","text":"cancel stubborn tool"}]}') \
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
  ($events | map(select(.type == "tool_result") | .exit_code)) == [126] and
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
    < <(print -r -- '{"type":"user","content":[{"type":"text","text":"cancel state tool"}]}') \
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
