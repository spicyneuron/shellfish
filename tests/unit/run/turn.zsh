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

# Startup materializes the header and system hook before a turn.
sf_test_session "$session"

stream=$(sf_test_turn $'two\nwords' "$session")
print -r -- "$stream" | jq -eRn -L "$ROOT" '
  include "lib/runtime/schema";
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_turn_usage"))[0]) as $usage |
  ($events | map(select(.type == "message" and .role == "assistant"))[0]) as $assistant |
  $events[0].role == "user" and
  ($events | any(.type == "_assistant_delta")) and
  ($usage | del(.type) | token_usage) and
  ($usage | has("cached_tokens")) and
  ($assistant.usage == ($usage | del(.type))) and
  ($events | map(select(.type == "message")) | length == 2) and
  ($events | map(select(.type == "message"))[0] | canonical_user_message) and
  ($events | map(select(.type == "message"))[1] | canonical_assistant_message) and
  $assistant.stop == "end"
' >/dev/null
jq -e '
  .system == "frozen system" and (.tools | length) == 1 and .tools[0].name == "shell" and
  .messages == [{role:"user",content:[{type:"text",text:"two\nwords"}]}] and
  .options.request.model == "test-model"
' "$request_capture" >/dev/null
jq -e -s '
  length == 4 and .[1] == {type:"system",content:"frozen system"} and
  .[2].role == "user" and .[3].role == "assistant"
' "$session" >/dev/null

# A capable backend discovers model context once and freezes it into the session.
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

# A configured context window is authoritative and skips backend discovery.
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

# An explicit null disables backend discovery too.
SF_TEST_RUNTIME=$(jq -c --arg command "$model_backend" --arg context "$context_backend" '
  .backend.command=$command | .backend.context_window_command=$context |
  .profile.context_window=null
' <<<"$base_runtime")
typeset disabled_session="$tmp/disabled.jsonl"
sf_test_session "$disabled_session"
sf_test_turn first "$disabled_session" >/dev/null
[[ ! -e $model_calls ]]

# Unavailable metadata does not fail generation and is not retried.
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

# Provider projection uses the synchronized records and does not reread disk.
typeset memory_request="$tmp/memory-request.json"
SF_ROOT=$ROOT zsh -f -c '
  source "$SF_ROOT/libexec/run/turn.zsh"
  sf_session_begin_turn "$1" || exit
  mv "$1" "$1.saved" || exit
  print -rl -- "${SF_SESSION_RECORDS[@]}" |
    sf_request_build "$SF_SESSION[runtime]" "[]" >"$2"
  rc=$?
  mv "$1.saved" "$1"
  sf_session_reset
  exit $rc
' -- "$session" "$memory_request"
jq -e '
  .system == "frozen system" and
  .messages[-1].role == "assistant" and
  .messages[-1].content[0].text == "two\nwords\n"
' "$memory_request" >/dev/null

# Reasoning and text deltas share one zero-based sequence per provider response,
# so a client that observes sequence zero knows it has the response from its
# beginning.
stream=$(sf_test_turn 'think about two words' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson |
    select(.type | IN("_assistant_delta","_assistant_reasoning_delta"))] as $deltas |
  ($deltas | map(.type) | unique | length) == 2 and
  ($deltas | map(.index) | unique) == [0,1] and
  ($deltas | map(.seq)) == [range(0; $deltas | length)]
' >/dev/null

# Each provider response inside a tool loop restarts the sequence at zero.
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 sf_test_turn 'call a helper' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson | select(.type | IN("_backend_request_start",
    "_assistant_delta","_assistant_reasoning_delta"))] as $events |
  ($events | reduce .[] as $event ([];
    if $event.type == "_backend_request_start" then . + [[]]
    else .[0:-1] + [.[-1] + [$event.seq]] end)) as $responses |
  ($responses | length) == 2 and
  all($responses[]; length > 0 and . == [range(0; length)])
' >/dev/null

# Disallowed calls receive ordinary results and the provider continues.
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_NAME=unknown \
  SF_TEST_BACKEND_TOOL_COUNT=2 sf_test_turn 'request bypass' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson | select(.role == "tool_result")] as $results |
  ($results | map(.exit_code)) == [127,127]
' >/dev/null
assert_canonical_session "$session" end

# Reserved bypass fields stay in the transcript but never reach the tool, which
# rejects input it does not declare.
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_BYPASS=true \
  SF_TEST_BACKEND_TOOL_COMMAND='print -r -- ran' \
  sf_test_turn 'call a helper' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.role == "tool_result")] as $results |
  [$events[] | select(.role == "assistant") | .content[] |
    select(.type == "tool_call")] as $calls |
  ($results | map(.exit_code)) == [0] and
  $results[0].content == "ran\n" and
  ($calls | length) == 1 and
  $calls[0].input.request_sandbox_bypass == true and
  ($calls[0].input.sandbox_bypass_reason | length) > 0 and
  $calls[0].input.command == "print -r -- ran"
' >/dev/null

# Provider failure after the user commit closes the durable turn canonically.
stream=$(sf_test_turn 'retry error later' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  $events[-2].role == "assistant" and $events[-2].stop == "end" and
  $events[-1].type == "_turn_error" and
  ($events[-1].message | contains("test backend failure"))
' >/dev/null

# Visible content from an incomplete provider response is committed for replay,
# while incomplete tool intent and usage remain transient.
typeset partial_backend="$tmp/partial-backend" partial_capture="$tmp/partial-request.json"
cat >"$partial_backend" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
if jq -e '.messages[-1].content[0].text == "next"' <<<"$request" >/dev/null; then
  print -r -- "$request" >"$PARTIAL_CAPTURE"
  print -r -- '{"type":"_assistant_delta","index":0,"text":"continued"}'
  print -r -- '{"type":"_assistant_response_end","stop":"end"}'
  exit
fi
print -r -- '{"type":"_assistant_reasoning_delta","index":0,"text":"partial thought"}'
print -r -- '{"type":"_assistant_reasoning_opaque","index":0,"opaque":{"id":"reasoning_1","encrypted_content":"secret"}}'
print -r -- '{"type":"_assistant_delta","index":1,"text":"partial answer"}'
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
  ($events | map(select(.role == "assistant"))[-1]) as $assistant |
  ($assistant | canonical_assistant_message) and
  $assistant == {
    type:"message",role:"assistant",stop:"length",content:[
      {type:"reasoning",text:"partial thought",opaque:{id:"reasoning_1",encrypted_content:"secret"}},
      {type:"text",text:"partial answer"}
    ]
  } and
  ($events[-1].type == "_turn_error") and
  ($events[-1].message | contains("partial backend failure"))
' >/dev/null
assert_canonical_session "$partial_response_session" length
jq -e -s '
  (.[-1] | has("usage") | not) and
  (.[-1].content | all(.type != "tool_call"))
' "$partial_response_session" >/dev/null
stream=$(PARTIAL_CAPTURE="$partial_capture" sf_test_turn next "$partial_response_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "assistant"))[-1].content[0].text) == "continued"
' >/dev/null
jq -e '
  .messages[-2] == {role:"assistant",stop:"length",content:[
    {type:"reasoning",text:"partial thought",opaque:{id:"reasoning_1",encrypted_content:"secret"}},
    {type:"text",text:"partial answer"}
  ]} and .messages[-1] == {role:"user",content:[{type:"text",text:"next"}]}
' "$partial_capture" >/dev/null
SF_TEST_RUNTIME=$saved_runtime

# A partial append failure is fatal and emits no uncommitted durable record.
# The next reader repairs the fragment.
typeset partial_session="$tmp/partial.jsonl"
typeset partial_stream="$tmp/partial.stream"
integer partial_status=0
sf_test_session "$partial_session"
cp "$partial_session" "$tmp/partial-before.jsonl"
SF_ROOT=$ROOT zsh -f -c '
  source "$SF_ROOT/libexec/run/turn.zsh"
  SF_RUN[jsonl]=1
  sf_session_append() {
    print -rn -- "{\"type\":\"message\"" >>"$SF_SESSION_PATH"
    sf_session_fail "cannot append session record: $SF_SESSION_PATH"
    return 1
  }
  message="{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"partial write\"}]}"
  sf_run_turn "$message" "$1" 0 "partial write"
' -- "$partial_session" >"$partial_stream" || partial_status=$?
(( partial_status == 1 )) || fail 'partial append failure exited successfully'
print -r -- "$(<"$partial_stream")" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(.type)) == ["_turn_error"] and
  ($events[-1].message | contains("cannot append session record")) and
  ($events | any(.type | IN("session","system","message","context")) | not)
' >/dev/null
sf_session_begin_turn "$partial_session"
sf_session_reset
cmp -s "$tmp/partial-before.jsonl" "$partial_session" ||
  fail 'opening did not repair the partial append'

# Configured system text and session-start context reach the provider request,
# but the fixture echoes only the submitted prompt.
typeset echo_session="$tmp/echo.jsonl"
sf_test_session "$echo_session"
sf_session_begin_turn "$echo_session"
sf_session_append '{"type":"context","hook":"session_start","script":"fixture","content":"startup context"}'
sf_session_reset
stream=$(sf_test_turn 'plain prompt' "$echo_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson | select(.role == "assistant")] as $messages |
  $messages[-1].content[-1] == {type:"text",text:"plain prompt\n"}
' >/dev/null
jq -e '
  .system == "frozen system" and
  (.messages[-1].content[0].text | contains("<hook name=\"session_start\">\n<context script=\"fixture\">"))
' "$request_capture" >/dev/null

# A tool response commits its call and result before the provider continues.
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 sf_test_turn 'use a tool' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "assistant"))[0] |
    .stop == "tool_calls" and .content[0] == {type:"text",text:"use a tool\n"}) and
  ($events | map(select(.role == "tool_result"))[0] |
    .call_id == "call_1" and .exit_code == 0) and
  ($events | map(select(.role == "assistant"))[-1].stop) == "end"
' >/dev/null
assert_canonical_session "$session" end
jq -e '
  (.tools | length) == 1 and .tools[0].name == "shell" and
  (.tools[0].input_schema.properties | has("request_sandbox_bypass") | not) and
  .messages[-1].role == "tool_result"
' "$request_capture" >/dev/null

# Replacing a lorem prompt with the sampler does not discard its tool keyword.
typeset lorem_session="$tmp/lorem.jsonl"
sf_test_session "$lorem_session"
stream=$(sf_test_turn 'lorem tool' "$lorem_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "_turn_error") | not) and
  ($events | map(select(.role == "assistant"))[0].stop) == "tool_calls" and
  ($events | map(select(.role == "tool_result")) | length) == 1 and
  ($events | map(select(.role == "assistant"))[-1].stop) == "end"
' >/dev/null
