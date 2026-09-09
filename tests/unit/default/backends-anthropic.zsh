#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

sf_test_tmp backends-anthropic
typeset run="$ROOT/share/default/backends/anthropic/run"
typeset context_window="$ROOT/share/default/backends/anthropic/context_window"
typeset req="$tmp/request.json"
typeset res="$tmp/output.jsonl"

# Adapter module lookup must ignore the caller's working tree.
mkdir -p "$tmp/lib/runtime"
print -r -- 'def canonical_request(:' >"$tmp/lib/runtime/schema.jq"

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
  "options": {"request":{"model":"claude-test"}},
  "transport": {"endpoint":"https://api.anthropic.com/v1/messages","insecure_tls":false,"http_timeout":30,"http_stall":10}
}
EOF

assert_usage() {
  jq -e -s -L "$ROOT" '
    include "lib/runtime/schema";
    include "lib/request";
    map(select(.type == "_turn_usage"))[0] as $event |
    assemble_backend_response(canonical_backend_response_events; canonical_assistant_message) as $message |
    ($event | del(.type)) == {
      input_tokens:100, output_tokens:7, cached_tokens:85, reasoning_tokens:3
    } and
    $message.usage == ($event | del(.type)) and
    ($message | canonical_assistant_message) and
    $message.content[0] == {type:"text",text:"ok"}
  ' "$res" >/dev/null
}

# Buffered response.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":85,"output_tokens":7,"output_tokens_details":{"thinking_tokens":3}}}
EOF
(builtin cd -- "$tmp" && ANTHROPIC_API_KEY=test zsh -f "$run" <"$req" >"$res")
assert_usage

# Streaming usage arrives in separate start and delta events.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":85,"output_tokens":0}}}
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7,"output_tokens_details":{"thinking_tokens":3}}}
data: {"type":"message_stop"}

EOF
ANTHROPIC_API_KEY=test zsh -f "$run" <"$req" >"$res"
assert_usage

# Streaming thinking payloads and tool input retain content-block indexes.
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
jq -e -s -L "$ROOT" '
  include "lib/runtime/schema";
  include "lib/request";
  assemble_backend_parts(canonical_backend_response_events; canonical_assistant_message) as $parts |
  ($parts.message.stop == "tool_calls") and
  ($parts.message.content == [{type:"reasoning",text:"why",opaque:{type:"thinking",thinking:"why",signature:"signed"}}]) and
  ($parts.calls == [{type:"tool_call",id:"call_1",name:"shell",input:{command:"pwd"}}])
' "$res" >/dev/null

# Model metadata uses the provider's authoritative maximum input count.
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

# A flat call batch regroups into the shape this provider expects.
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
  "options": {"request":{"model":"claude-test"}},
  "transport": {"endpoint":"https://api.anthropic.com/v1/messages","insecure_tls":false,"http_timeout":30,"http_stall":10}
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

# A response whose only output was calls keeps its calls instead of a placeholder.
jq -c '.messages[1].content = []' "$batch_request" >"$tmp/calls-only.json"
ANTHROPIC_API_KEY=test zsh -f "$run" <"$tmp/calls-only.json" >"$res"
jq -e '(.messages[1].content | map(.type)) == ["tool_use","tool_use"]'   "$BACKEND_TEST_BODY" >/dev/null || fail 'a call-only message was treated as empty'
