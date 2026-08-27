#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source session/main.zsh hooks.zsh

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

# Startup materializes the header and configured system prompt before a turn.
sf_test_session "$session"

stream=$(sf_test_turn $'two\nwords' "$session")
print -r -- "$stream" | jq -eRn -L "$ROOT/lib" '
  include "runtime/schema";
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

# Provider projection uses the synchronized records and does not reread disk.
typeset memory_request="$tmp/memory-request.json"
SF_ROOT=$ROOT zsh -f -c '
  source "$SF_ROOT/lib/exec.zsh"
  sf_session_open "$1" || exit
  mv "$1" "$1.saved" || exit
  sf_exec_request "[]" >"$2"
  rc=$?
  mv "$1.saved" "$1"
  sf_session_close || rc=1
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
jq -L "$ROOT/lib" -e -s '
  include "runtime/schema";
  (.[1:] | canonical_session_records) and .[-1].stop == "end"
' "$session" >/dev/null

# Provider failure after the user commit closes the durable turn canonically.
stream=$(sf_test_turn 'retry error later' "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  $events[-2].role == "assistant" and $events[-2].stop == "end" and
  $events[-1].type == "_exec_error" and
  ($events[-1].message | contains("test backend failure"))
' >/dev/null

# A partial append failure is fatal, emits no uncommitted durable record, and
# releases the session lock. The next owner repairs the fragment.
typeset partial_session="$tmp/partial.jsonl"
typeset partial_stream="$tmp/partial.stream"
integer partial_status=0
sf_test_session "$partial_session"
cp "$partial_session" "$tmp/partial-before.jsonl"
SF_ROOT=$ROOT zsh -f -c '
  source "$SF_ROOT/lib/exec.zsh"
  SF_EXEC[jsonl]=1
  sf_session_append() {
    print -rn -- "{\"type\":\"message\"" >>"$SF_SESSION_PATH"
    sf_session_fail "cannot append session record: $SF_SESSION_PATH"
    return 1
  }
  message="{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"partial write\"}]}"
  sf_exec_turn "$message" "$1" 0
' -- "$partial_session" >"$partial_stream" || partial_status=$?
(( partial_status == 1 )) || fail 'partial append failure exited successfully'
print -r -- "$(<"$partial_stream")" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(.type)) == ["_exec_error"] and
  ($events[-1].message | contains("cannot append session record")) and
  ($events | any(.type | IN("session","system","message","context")) | not)
' >/dev/null
assert_session_unlocked "$partial_session"
sf_session_open "$partial_session"
sf_session_close
cmp -s "$tmp/partial-before.jsonl" "$partial_session" ||
  fail 'opening did not repair the partial append'

# Configured system text and session-start context reach the provider request,
# but the fixture echoes only the submitted prompt.
typeset echo_session="$tmp/echo.jsonl"
sf_test_session "$echo_session"
sf_session_open "$echo_session"
sf_session_append '{"type":"context","tag":"session_start","hook":"fixture","content":"startup context"}'
sf_session_close
stream=$(sf_test_turn 'plain prompt' "$echo_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson | select(.role == "assistant")] as $messages |
  $messages[-1].content[-1] == {type:"text",text:"plain prompt\n"}
' >/dev/null
jq -e '
  .system == "frozen system" and
  (.messages[-1].content[0].text | contains("<session_start hook=\"fixture\">"))
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
jq -L "$ROOT/lib" -e -s '
  include "runtime/schema";
  (.[1:] | canonical_session_records) and .[-1].stop == "end"
' "$session" >/dev/null
jq -e '
  (.tools | length) == 1 and .tools[0].name == "shell" and
  (.tools[0].input_schema.properties | has("request_sandbox_bypass") | not) and
  .messages[-1].role == "tool_result"
' "$request_capture" >/dev/null

# A later owner recovers an interrupted provider state before the next request.
sf_session_open "$session"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"interrupted"}]}'
sf_session_close
stream=$(sf_test_turn next "$session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  $events[0].role == "assistant" and $events[0].stop == "end" and
  $events[1].role == "user"
' >/dev/null
