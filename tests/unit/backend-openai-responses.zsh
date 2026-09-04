#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"

sf_test_tmp backend-openai-responses
typeset run="$ROOT/default/backends/openai-responses/run"
typeset codex_context_window="$ROOT/default/backends/codex/context_window"
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
{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":85},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":3}}}
EOF
SHELLFISH_API_KEY=test zsh -f "$run" <"$req" >"$res"
assert_usage

# An incomplete response discards partial function-call arguments.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"status":"incomplete","output":[{"type":"function_call","call_id":"call_cut","name":"shell","arguments":"{\"command\":"}],"usage":{"input_tokens":10,"output_tokens":5}}
EOF
SHELLFISH_API_KEY=test zsh -f "$run" <"$req" >"$res"
jq -e -s -L "$ROOT" '
  include "lib/runtime/schema";
  include "lib/request";
  assemble_backend_response(canonical_backend_response_events; canonical_assistant_message) == {type:"message",role:"assistant",stop:"length",content:[],usage:{input_tokens:10,output_tokens:5}}
' "$res" >/dev/null

# Codex model metadata comes from the installed CLI's offline bundled catalog.
cat >"$tmp/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$CODEX_TEST_ARGS"
cat "$CODEX_TEST_CATALOG"
EOF
chmod +x "$tmp/codex"
export CODEX_TEST_ARGS="$tmp/codex-args"
export CODEX_TEST_CATALOG="$tmp/codex-models.json"
cat >"$tmp/codex-request.json" <<'EOF'
{
  "format_version": 1,
  "system": "test",
  "messages": [{"role":"user","content":[{"type":"text","text":"hello"}]}],
  "tools": [],
  "options": {"request":{"model":"gpt-codex-test"}},
  "transport": {"endpoint":"https://chatgpt.com/backend-api/codex/responses","insecure_tls":false,"http_timeout":30,"http_stall":10}
}
EOF
cat >"$CODEX_TEST_CATALOG" <<'EOF'
{"models":[{"slug":"other","context_window":1000},{"slug":"gpt-codex-test","context_window":272000}]}
EOF
zsh -f "$codex_context_window" <"$tmp/codex-request.json" >"$res"
jq -e '. == {context_window:272000}' "$res" >/dev/null
assert_equal 'debug models --bundled' "$(<"$CODEX_TEST_ARGS")"

print -r -- '{"models":[]}' >"$CODEX_TEST_CATALOG"
if zsh -f "$codex_context_window" <"$tmp/codex-request.json" >"$res"; then
  fail 'unknown Codex model context was reported as available'
fi

# Streaming response.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
data: {"type":"response.output_text.delta","delta":"ok"}
data: {"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":85},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":3}}}}

EOF
SHELLFISH_API_KEY=test zsh -f "$run" <"$req" >"$res"
assert_usage

# Streaming reasoning metadata and tool arguments retain provider output indexes.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
data: {"type":"response.reasoning_summary_text.delta","output_index":0,"item_id":"rs_1","summary_index":0,"delta":"why"}
data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"why"}],"encrypted_content":"secret"}}
data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":""}}
data: {"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"command\":"}
data: {"type":"response.function_call_arguments.done","output_index":1,"arguments":"{\"command\":\"pwd\"}"}
data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":"{\"command\":\"pwd\"}"}}
data: {"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":5}}}

EOF
SHELLFISH_API_KEY=test zsh -f "$run" <"$req" >"$res"
jq -e -s -L "$ROOT" '
  include "lib/runtime/schema";
  include "lib/request";
  assemble_backend_response(canonical_backend_response_events; canonical_assistant_message) |
  .stop == "tool_calls" and
  .content[0] == {type:"reasoning",text:"why",opaque:{type:"reasoning",id:"rs_1",summary:[{type:"summary_text",text:"why"}],encrypted_content:"secret"}} and
  .content[1] == {type:"tool_call",id:"call_1",name:"shell",input:{command:"pwd"}}
' "$res" >/dev/null
