#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"

sf_test_tmp backend-openai-responses
typeset run="$ROOT/default/backends/openai-responses/run"
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
  "options": {"request":{"model":"gpt-test"}},
  "transport": {"endpoint":"https://api.openai.test","insecure_tls":false,"http_timeout":30,"http_stall":10}
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
{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":85},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":3}}}
EOF
SHELLFISH_API_KEY=test zsh -f "$run" <"$req" >"$res"
assert_usage

# Streaming response.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
data: {"type":"response.output_text.delta","delta":"ok"}
data: {"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":85},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":3}}}}

EOF
SHELLFISH_API_KEY=test zsh -f "$run" <"$req" >"$res"
assert_usage
