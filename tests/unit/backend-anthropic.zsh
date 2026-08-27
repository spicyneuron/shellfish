#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"

sf_test_tmp backend-anthropic
typeset run="$ROOT/default/backends/anthropic/run"
typeset req="$tmp/request.json"
typeset res="$tmp/output.jsonl"

cat >"$tmp/curl" <<'EOF'
#!/bin/sh
cat "$BACKEND_TEST_RESPONSE"
printf 200 >&2
EOF
chmod +x "$tmp/curl"
export PATH="$tmp:$PATH"
export BACKEND_TEST_RESPONSE="$tmp/response"

cat >"$req" <<'EOF'
{
  "format_version": 1,
  "system": "test",
  "messages": [{"role":"user","content":[{"type":"text","text":"hello"}]}],
  "tools": [],
  "options": {"request":{"model":"claude-test"}},
  "transport": {"endpoint":"https://api.anthropic.test","insecure_tls":false,"http_timeout":30,"http_stall":10}
}
EOF

assert_usage() {
  jq -e -s -L "$ROOT/lib" '
    include "runtime/schema";
    map(select(.type == "_turn_usage"))[0] as $event |
    map(select(.type == "message"))[0] as $message |
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
