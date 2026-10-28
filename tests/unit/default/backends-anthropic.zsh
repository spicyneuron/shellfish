#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

sf_test_tmp backends-anthropic
typeset run="$ROOT/share/backends/anthropic/run"
typeset context_window="$ROOT/share/backends/anthropic/context_window"
typeset req="$tmp/request.json"
typeset res="$tmp/output.jsonl"

cat >"$tmp/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BACKEND_TEST_ARGS"
while (($#)); do
  case $1 in
    --data-binary) cp "${2#@}" "$BACKEND_TEST_BODY" ; shift 2 ;;
    *) shift ;;
  esac
done
cat "$BACKEND_TEST_RESPONSE"
printf 200 >&2
EOF
chmod +x "$tmp/curl"
export PATH="$tmp:$PATH"
export BACKEND_TEST_RESPONSE="$tmp/response"
export BACKEND_TEST_ARGS="$tmp/curl-args"
export BACKEND_TEST_BODY="$tmp/body"

cat >"$req" <<'EOF'
{
  "format_version": 1,
  "system": "test",
  "messages": [{"type":"user","content":[{"type":"text","text":"hello"}]}],
  "tools": [],
  "request":{"model":"claude-test","max_tokens":10,
    "max_completion_tokens":88,"max_output_tokens":99,
    "reasoning":{"effort":"high"},"reasoning_effort":"medium",
    "thinking":{"type":"disabled"},
    "output_config":{"foo":"keep","effort":"low","format":{"type":"text"}},
    "response_schema":{"type":"object","required":["answer"],"properties":{"answer":{"type":"string"}}}},
  "endpoint":"https://api.anthropic.com/v1/messages"
}
EOF

assert_usage() {
  sf_test_backend_response "$res" || fail 'anthropic emitted an invalid stream'
  jq -e '
    .usage == {input_tokens:100, output_tokens:7, cached_tokens:85, reasoning_tokens:3} and
    .content == [{type:"text",text:"ok"}]
  ' <<<"$REPLY" >/dev/null || fail 'anthropic lost text or usage'
}

# Parse buffered responses.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":85,"output_tokens":7,"output_tokens_details":{"thinking_tokens":3}}}
EOF
(builtin cd -- "$tmp" && ANTHROPIC_API_KEY=test zsh -f "$run" <"$req" >"$res")
assert_usage
jq -e -s 'map(select(.type == "_assistant_message_delta") | .text) == ["ok"]' \
  "$res" >/dev/null || fail 'anthropic did not stream a buffered response as deltas'
jq -e '
  (.response_schema | not) and .max_tokens == 99 and
  .thinking == {type:"adaptive"} and
  .output_config == {foo:"keep",effort:"medium",format:{type:"json_schema",
    schema:{type:"object",required:["answer"],properties:{answer:{type:"string"}}}}}
' "$BACKEND_TEST_BODY" >/dev/null || fail 'anthropic did not normalize common request parameters'

# Combine streamed usage events.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":85,"output_tokens":0}}}
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7,"output_tokens_details":{"thinking_tokens":3}}}
data: {"type":"message_stop"}

EOF
ANTHROPIC_API_KEY=test zsh -f "$run" <"$req" >"$res"
assert_usage

# Preserve streamed reasoning and calls.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0}}}
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"why"}}
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}
data: {"type":"content_block_stop","index":0}
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_1","name":"shell","input":{}}}
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"pwd\"}"}}
data: {"type":"content_block_stop","index":1}
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}
data: {"type":"message_stop"}

EOF
ANTHROPIC_API_KEY=test zsh -f "$run" <"$req" >"$res"
sf_test_backend_response "$res" || fail 'anthropic emitted an invalid call stream'
jq -e '
  .stop == "tool_calls" and
  .content == [
    {type:"reasoning",text:"why",opaque:{type:"thinking",thinking:"why",signature:"signed"}},
    {type:"tool_call",id:"call_1",name:"shell",input:{command:"pwd"}}]
' <<<"$REPLY" >/dev/null || fail 'anthropic lost streamed reasoning or calls'
jq -e -s 'map(select(.type == "_assistant_reasoning_delta") | .text) == ["why"]' \
  "$res" >/dev/null || fail 'anthropic did not preview its reasoning'

# Read Anthropic model limits.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"data":[{"id":"other","max_input_tokens":1000},{"id":"claude-test","max_input_tokens":200000,"max_tokens":64000}]}
EOF
(builtin cd -- "$tmp" && ANTHROPIC_API_KEY=test zsh -f "$context_window" <"$req" >"$res")
jq -e '. == {context_window:200000}' "$res" >/dev/null
grep -qx 'https://api.anthropic.com/v1/models?limit=1000' "$BACKEND_TEST_ARGS"

cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"data":[]}
EOF
if ANTHROPIC_API_KEY=test zsh -f "$context_window" <"$req" >"$res"; then
  fail 'unknown model context was reported as available'
fi

# Regroup flat call batches.
typeset batch_request="$tmp/batch-request.json"
cat >"$batch_request" <<'JSON'
{
  "format_version": 1,
  "system": "test",
  "messages": [
    {"type":"user","content":[{"type":"text","text":"run both"}]},
    {"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"working"}]},
    {"type":"tool_call","id":"call_1","name":"shell","input":{"command":"pwd"}},
    {"type":"tool_result","call_id":"call_1","name":"shell","content":"/tmp","exit_code":0},
    {"type":"tool_call","id":"call_2","name":"shell","input":{"command":"ls"}},
    {"type":"tool_result","call_id":"call_2","name":"shell","content":"bad","exit_code":1}
  ],
  "tools": [],
  "request":{"model":"claude-test"},
  "endpoint":"https://api.anthropic.com/v1/messages"
}
JSON
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
EOF
ANTHROPIC_API_KEY=test zsh -f "$run" <"$batch_request" >"$res"
jq -e '
  (.messages | map(.role)) == ["user","assistant","user"] and
  .messages[1].content == [
    {type:"text",text:"working"},
    {type:"tool_use",id:"call_1",name:"shell",input:{command:"pwd"}},
    {type:"tool_use",id:"call_2",name:"shell",input:{command:"ls"}}
  ] and
  (.messages[2].content | map(.tool_use_id)) == ["call_1","call_2"] and
  (.messages[2].content | map(.is_error)) == [false,true]
' "$BACKEND_TEST_BODY" >/dev/null || fail 'anthropic did not regroup a call batch'

# The adapter always streams, so a stream option is refused.
jq -c '.request.stream = false' "$req" >"$tmp/no-stream.json"
if ANTHROPIC_API_KEY=test zsh -f "$run" <"$tmp/no-stream.json" >"$res" 2>"$tmp/error"; then
  fail 'anthropic accepted a stream option'
fi
grep -Fq -- 'invalid request' "$tmp/error" || fail 'anthropic did not explain the refused stream option'
