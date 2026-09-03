#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"

sf_test_tmp backend-anthropic
typeset run="$ROOT/default/backends/anthropic/run"
typeset context_window="$ROOT/default/backends/anthropic/context_window"
typeset req="$tmp/request.json"
typeset res="$tmp/output.jsonl"

cat >"$tmp/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$BACKEND_TEST_ARGS"
cat "$BACKEND_TEST_RESPONSE"
printf 200 >&2
EOF
chmod +x "$tmp/curl"
export PATH="$tmp:$PATH"
export BACKEND_TEST_RESPONSE="$tmp/response"
export BACKEND_TEST_ARGS="$tmp/curl-args"

cat >"$req" <<'EOF'
{
  "format_version": 1,
  "system": "test",
  "messages": [{"role":"user","content":[{"type":"text","text":"hello"}]}],
  "tools": [],
  "options": {"request":{"model":"claude-test"}},
  "transport": {"endpoint":"https://api.anthropic.com/v1/messages","insecure_tls":false,"http_timeout":30,"http_stall":10}
}
EOF

assert_usage() {
  jq -e -s -L "$ROOT/lib" '
    include "runtime/schema";
    map(select(.type == "_turn_usage"))[0] as $event |
    assemble_backend_response as $message |
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
SHELLFISH_API_KEY=test zsh -f "$run" <"$req" >"$res"
assert_usage

# Streaming usage arrives in separate start and delta events.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":85,"output_tokens":0}}}
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7,"output_tokens_details":{"thinking_tokens":3}}}
data: {"type":"message_stop"}

EOF
SHELLFISH_API_KEY=test zsh -f "$run" <"$req" >"$res"
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
SHELLFISH_API_KEY=test zsh -f "$run" <"$req" >"$res"
jq -e -s -L "$ROOT/lib" '
  include "runtime/schema";
  assemble_backend_response |
  .stop == "tool_calls" and
  .content[0] == {type:"reasoning",text:"why",opaque:{type:"thinking",thinking:"why",signature:"signed"}} and
  .content[1] == {type:"tool_call",id:"call_1",name:"shell",input:{command:"pwd"}}
' "$res" >/dev/null

# Model metadata uses the provider's authoritative maximum input count.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"data":[{"id":"other","max_input_tokens":1000},{"id":"claude-test","max_input_tokens":200000,"max_tokens":64000}]}
EOF
SHELLFISH_API_KEY=test zsh -f "$context_window" <"$req" >"$res"
jq -e '. == {context_window:200000}' "$res" >/dev/null
grep -qx 'https://api.anthropic.com/v1/models?limit=1000' "$BACKEND_TEST_ARGS"

cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"data":[]}
EOF
if SHELLFISH_API_KEY=test zsh -f "$context_window" <"$req" >"$res"; then
  fail 'unknown model context was reported as available'
fi
