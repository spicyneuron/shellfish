#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh

typeset stream
sf_test_tmp exec-stop-hooks
export XDG_STATE_HOME="$tmp/state"
export TEST_STATE_PATH="$tmp/turn-state"
typeset system_file="$tmp/system.md"
typeset request_capture="$tmp/request.json"
printf 'frozen system\n' >"$system_file"

sf_test_runtime "$system_file"
export SF_TEST_BACKEND_DELAY=0
export SF_TEST_BACKEND_REQUEST="$request_capture"

# Stop feedback triggers another request.
typeset stop_once="$tmp/stop-once"
cat >"$stop_once" <<'ZSH'
#!/usr/bin/env zsh
set -e
[[ $# == 2 && $1 == stop && $2 == <1-> ]]
[[ $SHELLFISH_TURN_ID == 1 ]] || exit 3
[[ $SHELLFISH_MODEL == test-model ]] || exit 4
[[ $0 == /* && -d ${0:A:h} ]] || exit 5
[[ ! -e $SHELLFISH_TURN_STATE/inherited ]] || exit 8
[[ -e $TEST_STATE_PATH ]] || print -rn -- "$SHELLFISH_TURN_STATE" >"$TEST_STATE_PATH"
input=$(cat)
print -r -- "$2|${input//$'\n'/\\n}" >>"$SHELLFISH_TURN_STATE/attempts"
jq -cn --argjson attempt "$2" '{state:[{name:"stop/attempt",value:$attempt}]}' >&3
if [[ ! -e $SHELLFISH_TURN_STATE/stopped ]]; then
  : >$SHELLFISH_TURN_STATE/stopped
  print -rn -- feedback
  print -rn -u2 -- first-local
  exit 10
fi
print -rn -- discarded
print -rn -u2 -- second-local
ZSH
chmod +x "$stop_once"
SF_TEST_RUNTIME=$(jq -c --arg hook "$stop_once" \
  '.harness.stop=[{command:$hook,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}]' <<<"$SF_TEST_RUNTIME")
typeset stop_session="$tmp/stop.jsonl"
sf_test_session "$stop_session"
sf_hooks_turn_state_create
typeset inherited_state=$SHELLFISH_TURN_STATE
: >"$inherited_state/inherited"
stream=$(sf_test_turn original "$stop_session")
[[ -d $inherited_state && $SHELLFISH_TURN_STATE == "$inherited_state" ]]
[[ -s $TEST_STATE_PATH ]] || fail 'stop script did not report its state directory'
typeset turn_state=$(<$TEST_STATE_PATH)
[[ ! -d $turn_state ]]
typeset stop_context='<hook name="stop">
<context script="stop-once">feedback</context>
</hook>'
print -r -- "$stream" | jq -eRn --arg executable "$stop_once" --arg context "$stop_context" '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "assistant")) | length) == 2 and
  (($events | map(select(.type == "hook_result"))) as $results |
    ($results | length) == 2 and ($results | map(.id) | unique | length) == 2 and
    ($results | map(del(.id,.model_text))) ==
      [{type:"hook_result",hook:"stop",name:"stop-once",input:"original\n",
        executable:$executable,exit_code:10},
       {type:"hook_result",hook:"stop",name:"stop-once",input:($context + "\n"),
        executable:$executable,exit_code:0}] and
    $results[0].model_text == $context and
    ($results[1].model_text | contains("discarded")) and
    ($events | map(select(.type == "state" or .type == "hook_result")) |
      map(if .type == "state" then [.name,.value]
        else ["result",(.model_text | contains("feedback")),
          (.model_text | contains("discarded"))] end)) ==
      [["stop/attempt",1],["result",true,false],
       ["stop/attempt",2],["result",false,true]])
' >/dev/null
sf_hooks_turn_state_cleanup
jq -e --arg context "$stop_context" '
  .messages[-2].type == "assistant" and
  .messages[-1].type == "user" and
  .messages[-1].content[0].text == $context
' "$request_capture" >/dev/null
jq -e -s '
  ([.[] | select(.type == "hook_result")] | length) == 2 and
  ([.[] | select((.model_text? // "") | contains("discarded"))] | length) == 1
' "$stop_session" >/dev/null
sf_hooks_turn_state_cleanup

# Stop hooks receive exact assistant text.
typeset text_backend="$tmp/text-backend"
cat >"$text_backend" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -- '{"type":"_assistant_message_delta","index":0,"text":"first\u0000\u001e\n"}'
print -r -- '{"type":"_assistant_reasoning_delta","index":1,"text":"omit"}'
print -r -- '{"type":"_assistant_message_delta","index":2,"text":"second\n"}'
print -r -- '{"type":"_assistant_end","stop":"end"}'
ZSH
chmod +x "$text_backend"
typeset text_stop="$tmp/text-stop"
cat >"$text_stop" <<'ZSH'
#!/usr/bin/env zsh
set -e
[[ $# == 2 && $1 == stop && $2 == 1 ]]
cmp -s /dev/stdin "$SHELLFISH_TURN_STATE/expected"
ZSH
chmod +x "$text_stop"
SF_TEST_RUNTIME=$(jq -c --arg hook "$text_stop" --arg backend "$text_backend" '
  .harness.stop=[{command:$hook,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}] | .backend.command=$backend
' <<<"$SF_TEST_RUNTIME")
typeset text_session="$tmp/stop-text.jsonl"
sf_test_session "$text_session"
sf_hooks_turn_state_create
printf 'first\0\x1e\nsecond\n' >"$SHELLFISH_TURN_STATE/expected"
stream=$(sf_test_turn text "$text_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "assistant"))
' >/dev/null
sf_hooks_turn_state_cleanup
SF_TEST_RUNTIME=$(jq -c --arg backend "$ROOT/tests/fixtures/backend/run" \
  '.backend.command=$backend' <<<"$SF_TEST_RUNTIME")

# Stop retries can execute tools.
typeset tool_stop="$tmp/stop-feedback"
cat >"$tool_stop" <<'ZSH'
#!/usr/bin/env zsh
if [[ ! -e $SHELLFISH_TURN_STATE/tool-feedback ]]; then
  : >$SHELLFISH_TURN_STATE/tool-feedback
  print -rn -- 'use a tool'
  exit 10
fi
ZSH
chmod +x "$tool_stop"
SF_TEST_RUNTIME=$(jq -c --arg hook "$tool_stop" \
  '.harness.stop=[{command:$hook,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}]' <<<"$SF_TEST_RUNTIME")
typeset tool_stop_session="$tmp/stop-tool.jsonl"
sf_test_session "$tool_stop_session"
stream=$(sf_test_turn original "$tool_stop_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "assistant") | .stop)) ==
    ["end","tool_calls","end"] and
  ($events | map(select(.type == "tool_result") | .exit_code)) == [0]
' >/dev/null

# Stop retries respect request limits.
typeset stop_always="$tmp/stop-always"
cat >"$stop_always" <<'ZSH'
#!/usr/bin/env zsh
print -rn -- again
exit 10
ZSH
chmod +x "$stop_always"
SF_TEST_RUNTIME=$(jq -c --arg hook "$stop_always" \
  '.harness.stop=[{command:$hook,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}] | .harness.max_requests_per_turn=1' \
  <<<"$SF_TEST_RUNTIME")
typeset limit_session="$tmp/stop-limit.jsonl"
sf_test_session "$limit_session"
stream=$(sf_test_turn bounded "$limit_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "hook_result" and
    ((.model_text? // "") | contains("again")))) | length) == 1 and
  $events[-1] == {type:"error",user_text:"provider request limit reached: 1"}
' >/dev/null
assert_canonical_session "$limit_session"

# Cancellation preserves committed stop feedback.
typeset cancel_ready="$tmp/cancel-ready"
typeset cancel_backend="$tmp/cancel-backend"
typeset cancel_context="$tmp/cancel-context"
print -rn -- "$stop_context" >"$cancel_context"
cat >"$cancel_backend" <<ZSH
#!/usr/bin/env zsh
request=\$(cat)
if jq -e --rawfile context "$cancel_context" '.messages[-1].type == "user" and
    .messages[-1].content[0].text == \$context' \
    <<<"\$request" >/dev/null; then
  : >"$cancel_ready"
  sleep 10
else
  print -r -- '{"type":"_assistant_message_delta","index":0,"text":"original\\n"}'
  print -r -- '{"type":"_assistant_end","stop":"end"}'
fi
ZSH
chmod +x "$cancel_backend"

SF_TEST_RUNTIME=$(jq -c --arg hook "$stop_once" --arg backend "$cancel_backend" '
  .harness.stop=[{command:$hook,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}] | .harness.max_requests_per_turn=8 | .backend.command=$backend
' <<<"$SF_TEST_RUNTIME")
typeset cancel_session="$tmp/stop-cancel.jsonl"
typeset cancel_stream="$tmp/stop-cancel.stream"
sf_test_session "$cancel_session"
"$ROOT/bin/shellfish" run --jsonl --session "$cancel_session" \
  < <(print -r -- '{"type":"user","content":[{"type":"text","text":"wait for retry"}]}') \
  >"$cancel_stream" &
integer cancel_pid=$! cancel_status=0 cancel_polls=0
while [[ ! -e $cancel_ready ]] && (( cancel_polls++ < 250 )); do
  sleep 0.02
done
[[ -e $cancel_ready ]] || {
  kill -TERM "$cancel_pid" 2>/dev/null
  wait "$cancel_pid" 2>/dev/null || true
  fail 'backend did not begin the stop-script retry'
}
kill -TERM "$cancel_pid"
wait "$cancel_pid" || cancel_status=$?
(( cancel_status == 143 ))
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "hook_result" and .hook == "stop" and
    ((.model_text? // "") | contains("feedback")))) | length) == 1 and
  ($events | map(select(.type == "assistant")) | length) == 1
' <"$cancel_stream" >/dev/null
assert_canonical_session "$cancel_session"
jq -e -s '
  ([.[] | select(.type == "hook_result" and .hook == "stop" and
    ((.model_text? // "") | contains("feedback")))] | length) == 1
' "$cancel_session" >/dev/null
