#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh

typeset stream
sf_test_tmp exec-turn
export XDG_STATE_HOME="$tmp/state"
typeset session="$tmp/session.jsonl"
typeset system_file="$tmp/system.md"
typeset request_capture="$tmp/request.json"
printf 'frozen system\n' >"$system_file"

sf_test_runtime "$system_file"
export SF_TEST_BACKEND_DELAY=0
export SF_TEST_BACKEND_REQUEST="$request_capture"

# Startup materializes the session runtime.
sf_test_session "$session"

stream=$(sf_test_turn $'two\nwords' "$session")
print -r -- "$stream" | jq -eRn -L "$ROOT" '
  include "lib/runtime/schema";
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "assistant"))[0]) as $assistant |
  $events[0].type == "user" and
  ($events | any(.type == "_assistant_message_delta")) and
  ($events | any(.type == "_turn_usage")) and
  ($assistant.usage | token_usage) and
  ($assistant.usage | has("cached_tokens")) and
  ($events | map(select(.type == "user" or .type == "assistant")) | length == 2) and
  ($events | map(select(.type == "user"))[0] | canonical_user_message) and
  ($events | map(select(.type == "assistant"))[0] | canonical_assistant_message) and
  $assistant.stop == "end"
' >/dev/null
jq -e '
  .system == "frozen system" and (.tools | length) == 1 and .tools[0].name == "shell" and
  .messages == [{type:"user",content:[{type:"text",text:"two\nwords"}]}] and
  .options.request.model == "test-model"
' "$request_capture" >/dev/null
jq -e -s '
  length == 4 and .[1] == {type:"system",content:"frozen system"} and
  .[2].type == "user" and .[3].type == "assistant"
' "$session" >/dev/null

# Context discovery is frozen once.
typeset model_backend="$tmp/model-backend" context_backend="$tmp/context-backend"
typeset model_calls="$tmp/model-calls"
typeset base_runtime=$SF_TEST_RUNTIME
cat >"$model_backend" <<ZSH
#!/usr/bin/env zsh
exec "$SF_TEST_BACKEND"
ZSH
cat >"$context_backend" <<ZSH
#!/usr/bin/env zsh
print -r -- context >>"$model_calls"
if [[ -n \${MODEL_CONTEXT_MISSING-} ]]; then
  print -r -- '{}'
  exit
fi
print -r -- '{"context_window":128000}'
ZSH
chmod +x "$model_backend" "$context_backend"
SF_TEST_RUNTIME=$(jq -c --arg command "$model_backend" --arg context "$context_backend" \
  '.backend.command=$command | .backend.context_window_command=$context' <<<"$base_runtime")
typeset discovered_session="$tmp/discovered.jsonl"
sf_test_session "$discovered_session"
stream=$(sf_test_turn first "$discovered_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type == "_session_update")] ==
    [{type:"_session_update",runtime:$events[1].runtime}] and
  $events[1].runtime.profile.context_window == 128000
' >/dev/null
jq -e 'select(.type == "session") | .profile.context_window == 128000' \
  "$discovered_session" >/dev/null
sf_test_turn second "$discovered_session" >/dev/null
(( $(wc -l <"$model_calls") == 1 ))

# Configured context skips discovery.
SF_TEST_RUNTIME=$(jq -c --arg command "$model_backend" --arg context "$context_backend" '
  .backend.command=$command | .backend.context_window_command=$context |
  .profile.context_window=200000
' <<<"$base_runtime")
typeset configured_session="$tmp/configured.jsonl"
rm -f "$model_calls"
sf_test_session "$configured_session"
stream=$(sf_test_turn first "$configured_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] | any(.type == "_session_update") | not
' >/dev/null
[[ ! -e $model_calls ]]

# Null context disables discovery.
SF_TEST_RUNTIME=$(jq -c --arg command "$model_backend" --arg context "$context_backend" '
  .backend.command=$command | .backend.context_window_command=$context |
  .profile.context_window=null
' <<<"$base_runtime")
typeset disabled_session="$tmp/disabled.jsonl"
sf_test_session "$disabled_session"
sf_test_turn first "$disabled_session" >/dev/null
[[ ! -e $model_calls ]]

# Missing context is not retried.
SF_TEST_RUNTIME=$(jq -c --arg command "$model_backend" --arg context "$context_backend" \
  '.backend.command=$command | .backend.context_window_command=$context' <<<"$base_runtime")
typeset unavailable_session="$tmp/unavailable.jsonl"
sf_test_session "$unavailable_session"
stream=$(MODEL_CONTEXT_MISSING=1 sf_test_turn first "$unavailable_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] |
  any(.type == "_session_update" and .runtime.profile.context_window == null)
' >/dev/null
jq -e '
  select(.type == "session") |
  (.profile | has("context_window")) and .profile.context_window == null
' "$unavailable_session" >/dev/null
sf_test_turn second "$unavailable_session" >/dev/null
(( $(wc -l <"$model_calls") == 1 ))
sf_session_read_runtime "$unavailable_session"
jq -e '.profile.context_window == null' <<<"$REPLY" >/dev/null
SF_TEST_RUNTIME=$base_runtime

# Adapter events retain stream order.
stream=$(sf_test_turn 'think about two words' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson |
    select(.type | startswith("_assistant_") or . == "_turn_usage")] as $events |
  ($events | map(.type)) as $types |
  $types[0] == "_assistant_start" and $types[-1] == "_assistant_end" and
  ($types | any(. == "_turn_usage")) and
  ([$events[] | select(.type | endswith("_delta"))] |
    (map(.type) | unique | length) == 2 and
    (map(.index) | unique) == [0,1] and
    all(.[]; keys == ["index","text","type"]))
' >/dev/null

# Tool state precedes failed results.
typeset state_tool="$tmp/state-tool" state_session="$tmp/state-session.jsonl"
cat >"$state_tool" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -rn -u3 -- '{"state":[{"name":"tools/turn","value":"recorded"}]}'
print -rn -- failed
exit 7
ZSH
chmod +x "$state_tool"
SF_TEST_RUNTIME=$(jq -c --arg command "$state_tool" '
  .harness.tools[0].command=$command
' <<<"$base_runtime") || fail 'cannot prepare tool state runtime'
sf_test_session "$state_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 sf_test_turn 'record tool state' "$state_session")
# Tool-call deltas precede durable calls.
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson | select(.type == "state" or .type == "tool_result")] ==
    [{type:"state",name:"tools/turn",value:"recorded"},
     {type:"tool_result",call_id:"call_1",name:"shell",
      input:{command:"true"},stdout:"failed",stderr:"",exit_code:7}]
' >/dev/null || fail 'tool state was not emitted before its result'
jq -es '
  [.[] | select(.type == "state" or .type == "tool_result")] ==
    [{type:"state",name:"tools/turn",value:"recorded"},
     {type:"tool_result",call_id:"call_1",name:"shell",
      input:{command:"true"},stdout:"failed",stderr:"",exit_code:7}]
' "$state_session" >/dev/null || fail 'tool state was not durable before its result'
SF_TEST_RUNTIME=$base_runtime

print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(.type)) as $types |
  ($types | index("_assistant_tool_call_delta")) as $call |
  ($types | index("_assistant_end")) as $end |
  ($events | map(if .type == "assistant" and .stop? == "tool_calls"
    then .type else null end) | index("assistant")) as $assistant |
  ([$types[] | select(. == "_assistant_end")] | length) ==
    ([$types[] | select(. == "_assistant_start")] | length) and
  $call != null and $end != null and $assistant != null and
  $call < $end and $end < $assistant and
  any($events[0:$call][]; .type == "_assistant_message_delta") and
  ($events[$end] | .stop == "tool_calls") and
  all($events[] | select(.type == "_assistant_tool_call_delta");
    (.index | type == "number") and (.input | type == "string"))
' >/dev/null

# Unknown tools return ordinary results.
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_NAME=unknown \
  SF_TEST_BACKEND_TOOL_COUNT=2 sf_test_turn 'request bypass' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")] as $results |
  ($results | map(.exit_code)) == [127,127]
' >/dev/null
assert_canonical_session "$session" end

# Bypass fields stay outside tool input.
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  SF_TEST_BACKEND_TOOL_COMMAND='print -r -- ran' \
  sf_test_turn 'call a helper' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type == "tool_result")] as $results |
  [$events[] | select(.type == "_tool_activity")] as $calls |
  ($results | map(.exit_code)) == [0] and
  $results[0].stdout == "ran\n" and $results[0].stderr == "" and
  ($calls | length) == 1 and
  $calls[0].call_id == "call_1" and
  $calls[0].input.request_sandbox_bypass == true and
  ($calls[0].input.sandbox_bypass_reason | length) > 0 and
  $calls[0].input.command == "print -r -- ran"
' >/dev/null

# Provider failures close committed turns.
stream=$(sf_test_turn 'retry error later' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  $events[-1].type == "error" and
  ($events | map(select(.type == "assistant")) | length) == 0 and
  ($events[-1].user_text | contains("test backend failure"))
' >/dev/null
jq -e -s '
  .[-1].type == "error" and (.[-1].user_text | contains("test backend failure"))
' "$session" >/dev/null

# Partial responses retain visible content.
typeset partial_backend="$tmp/partial-backend" partial_capture="$tmp/partial-request.json"
cat >"$partial_backend" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
if jq -e '.messages[-1].content[0].text == "next"' <<<"$request" >/dev/null; then
  print -r -- "$request" >"$PARTIAL_CAPTURE"
  print -r -- '{"type":"_assistant_message_delta","index":0,"text":"continued"}'
  print -r -- '{"type":"_assistant_end","stop":"end"}'
  exit
fi
print -r -- '{"type":"_assistant_reasoning_delta","index":0,"text":"partial thought"}'
print -r -- '{"type":"_assistant_reasoning_opaque","index":0,"opaque":{"id":"reasoning_1","encrypted_content":"secret"}}'
print -r -- '{"type":"_assistant_message_delta","index":1,"text":"partial answer"}'
print -r -- '{"type":"_assistant_tool_call_delta","index":2,"id":"incomplete","name":"shell","input":"{\"command\":"}'
print -r -- '{"type":"_turn_usage","input_tokens":10,"output_tokens":4}'
print -u2 -r -- 'partial backend failure'
exit 7
ZSH
chmod +x "$partial_backend"
typeset saved_runtime=$SF_TEST_RUNTIME
SF_TEST_RUNTIME=$(jq -c --arg command "$partial_backend" '.backend.command=$command' \
  <<<$SF_TEST_RUNTIME)
typeset partial_response_session="$tmp/partial-response.jsonl"
sf_test_session "$partial_response_session"
stream=$(PARTIAL_CAPTURE="$partial_capture" sf_test_turn 'start' "$partial_response_session")
print -r -- "$stream" | jq -eRn -L "$ROOT" '
  include "lib/runtime/schema";
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "assistant"))[-1]) as $assistant |
  ($assistant | canonical_assistant_message) and
  $assistant == {
    type:"assistant",stop:"length",content:[
      {type:"reasoning",text:"partial thought",opaque:{id:"reasoning_1",encrypted_content:"secret"}},
      {type:"text",text:"partial answer"}
    ],
    usage:{input_tokens:10,output_tokens:4}
  } and
  ($events[-1].type == "error") and
  ($events[-1].user_text | contains("partial backend failure"))
' >/dev/null
assert_canonical_session "$partial_response_session"
jq -e -s '
  .[-1].type == "error" and
  (.[-1].user_text | contains("partial backend failure")) and
  (.[-2].usage == {input_tokens:10,output_tokens:4}) and
  (.[-2].content | all(.type != "tool_call"))
' "$partial_response_session" >/dev/null
stream=$(PARTIAL_CAPTURE="$partial_capture" sf_test_turn next "$partial_response_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "assistant"))[-1].content[0].text) == "continued"
' >/dev/null
jq -e '
  .messages[-2] == {type:"assistant",stop:"length",content:[
    {type:"reasoning",text:"partial thought",opaque:{id:"reasoning_1",encrypted_content:"secret"}},
    {type:"text",text:"partial answer"}
  ]} and .messages[-1] == {type:"user",content:[{type:"text",text:"next"}]}
' "$partial_capture" >/dev/null
SF_TEST_RUNTIME=$saved_runtime

# Readers repair partial appends.
typeset partial_session="$tmp/partial.jsonl"
typeset partial_stream="$tmp/partial.stream" partial_error="$tmp/partial.stderr"
integer partial_status=0
sf_test_session "$partial_session"
cp "$partial_session" "$tmp/partial-before.jsonl"
SF_ROOT=$ROOT zsh -f -c '
  source "$SF_ROOT/libexec/run/turn.zsh"
  SF_RUN[jsonl]=1
  sf_session_append() {
    local session=$1
    print -rn -- "{\"type\":\"user\"" >>"$session"
    sf_session_fail "cannot append session record: $session"
    return 1
  }
  message="{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"partial write\"}]}"
  sf_run_turn "$message" "$1" 0 "partial write"
' -- "$partial_session" >"$partial_stream" 2>"$partial_error" || partial_status=$?
(( partial_status == 1 )) || fail 'partial append failure exited successfully'
[[ ! -s $partial_stream ]]
[[ $(<"$partial_error") == *'cannot append session record'* ]] ||
  fail 'partial append failure omitted stderr diagnostic'
sf_session_begin_turn "$partial_session"
sf_session_reset
cmp -s "$tmp/partial-before.jsonl" "$partial_session" ||
  fail 'opening did not repair the partial append'

# A torn assistant commit discards its in-memory calls without execution.
typeset call_append_session="$tmp/call-append.jsonl"
typeset tool_marker="$tmp/tool-ran"
integer call_append_status=0
sf_test_session "$call_append_session"
SF_ROOT=$ROOT SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COMMAND=": >$tool_marker" \
  zsh -f -c '
  source "$SF_ROOT/libexec/run/turn.zsh"
  functions[sf_test_session_append]=$functions[sf_session_append]
  integer append_failed=0
  sf_session_append() {
    if (( ! append_failed )) &&
        jq -e '\''.type == "assistant" and .stop == "tool_calls"'\'' <<<$2 >/dev/null; then
      append_failed=1
      print -rn -- '\''{"type":"assistant"'\'' >>"$1"
      sf_session_fail "cannot append session record: $1"
      return 1
    fi
    sf_test_session_append "$@"
  }
  typeset -g SF_API_KEY="" SF_API_KEY_SOURCE=""
  SF_RUN[jsonl]=1
  message='\''{"type":"user","content":[{"type":"text","text":"recover call"}]}'\''
  sf_run_turn "$message" "$1" 0 "recover call"
' -- "$call_append_session" >/dev/null || call_append_status=$?
(( call_append_status == 1 )) || fail 'assistant append failure exited successfully'
[[ ! -e $tool_marker ]] || fail 'tool ran after its assistant failed to append'
assert_canonical_session "$call_append_session"
jq -e -s '
  all(.[]; .type != "tool_result") and
  .[-1].type == "error"
' "$call_append_session" >/dev/null || fail 'recovery retained an uncommitted call'

# A committed assistant is authoritative even when its append reports failure.
typeset committed_append_session="$tmp/committed-append.jsonl"
integer committed_append_status=0
sf_test_session "$committed_append_session"
SF_ROOT=$ROOT SF_TEST_BACKEND_TOOL_CALL=1 \
  zsh -f -c '
  source "$SF_ROOT/libexec/run/turn.zsh"
  functions[sf_test_session_append]=$functions[sf_session_append]
  integer append_failed=0
  sf_session_append() {
    if (( ! append_failed )) &&
        jq -e '\''.type == "assistant" and .stop == "tool_calls"'\'' <<<$2 >/dev/null; then
      append_failed=1
      sf_test_session_append "$@" || return
      sf_session_fail "reported assistant append failure"
      return 1
    fi
    sf_test_session_append "$@"
  }
  typeset -g SF_API_KEY="" SF_API_KEY_SOURCE=""
  SF_RUN[jsonl]=1
  message='\''{"type":"user","content":[{"type":"text","text":"close calls"}]}'\''
  sf_run_turn "$message" "$1" 0 "close calls"
' -- "$committed_append_session" >/dev/null || committed_append_status=$?
(( committed_append_status == 1 )) || fail 'reported assistant append failure exited successfully'
assert_canonical_session "$committed_append_session"
jq -e -s '
  .[-3].stop == "tool_calls" and
  (.[-2] | .type == "tool_result" and .call_id == "call_1" and
    .stderr == "tool call cancelled" and .exit_code == 126) and
  .[-1].type == "error"
' "$committed_append_session" >/dev/null ||
  fail 'recovery did not close calls from a committed assistant'

# System and hook context reach providers.
typeset echo_session="$tmp/echo.jsonl"
sf_test_session "$echo_session"
sf_session_begin_turn "$echo_session"
typeset startup_context='<hook name="session_start">
<context script="fixture">startup context</context>
</hook>'
sf_session_append "$echo_session" "$(jq -cn --arg text "$startup_context" '
  {type:"hook_result",hook:"session_start",id:"h1_1",name:"fixture",input:"",
   executable:"/hooks/fixture/run",model_text:$text,exit_code:0}')"
sf_session_reset
stream=$(sf_test_turn 'plain prompt' "$echo_session")
print -r -- "$stream" | jq -eRn --arg context "$startup_context" '
  [inputs | fromjson | select(.type == "assistant")] as $messages |
  $messages[-1].content[-1] == {type:"text",text:($context + "\n\nplain prompt\n")}
' >/dev/null
jq -e --arg context "$startup_context" '
  .system == "frozen system" and
  .messages[-1].content[0].text == $context + "\n\nplain prompt"
' "$request_capture" >/dev/null

# Tool results precede provider continuation.
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 sf_test_turn 'use a tool' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "assistant"))[0] |
    .stop == "tool_calls" and .content[0] == {type:"text",text:"use a tool\n"}) and
  ($events | map(select(.type == "tool_result"))[0] |
    .call_id == "call_1" and .exit_code == 0) and
  ($events | map(select(.type == "assistant"))[-1].stop) == "end"
' >/dev/null
assert_canonical_session "$session" end
jq -e '
  (.tools | length) == 1 and .tools[0].name == "shell" and
  (.tools[0].input_schema.properties | has("request_sandbox_bypass") | not) and
  .messages[-1].type == "tool_result"
' "$request_capture" >/dev/null
