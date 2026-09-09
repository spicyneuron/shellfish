#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

sf_test_tmp backends-openai-responses
typeset run="$ROOT/share/default/backends/openai-responses/run"
typeset codex_run="$ROOT/share/default/backends/codex/run"
typeset codex_context_window="$ROOT/share/default/backends/codex/context_window"
typeset req="$tmp/request.json"
typeset res="$tmp/output.jsonl"

# Adapter module lookup must ignore the caller's working tree.
mkdir -p "$tmp/lib/runtime"
print -r -- 'def canonical_request(:' >"$tmp/lib/runtime/schema.jq"

cat >"$tmp/curl" <<'EOF'
#!/usr/bin/env bash
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
export BACKEND_TEST_BODY="$tmp/body"

cat >"$req" <<'EOF'
{
  "format_version": 1,
  "system": "test",
  "messages": [{"type":"user","content":[{"type":"text","text":"hello"}]}],
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
(builtin cd -- "$tmp" && OPENAI_API_KEY=test zsh -f "$run" <"$req" >"$res")
assert_usage

# An incomplete response discards partial function-call arguments.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"status":"incomplete","output":[{"type":"function_call","call_id":"call_cut","name":"shell","arguments":"{\"command\":"}],"usage":{"input_tokens":10,"output_tokens":5}}
EOF
OPENAI_API_KEY=test zsh -f "$run" <"$req" >"$res"
jq -e -s -L "$ROOT" '
  include "lib/runtime/schema";
  include "lib/request";
  assemble_backend_response(canonical_backend_response_events; canonical_assistant_message) == {type:"assistant",stop:"length",content:[],usage:{input_tokens:10,output_tokens:5}}
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
  "messages": [{"type":"user","content":[{"type":"text","text":"hello"}]}],
  "tools": [],
  "options": {"request":{"model":"gpt-codex-test"}},
  "transport": {"endpoint":"https://chatgpt.com/backend-api/codex/responses","insecure_tls":false,"http_timeout":30,"http_stall":10}
}
EOF
cat >"$CODEX_TEST_CATALOG" <<'EOF'
{"models":[{"slug":"other","context_window":1000},{"slug":"gpt-codex-test","context_window":272000}]}
EOF
(builtin cd -- "$tmp" && zsh -f "$codex_context_window" <"$tmp/codex-request.json" >"$res")
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
OPENAI_API_KEY=test zsh -f "$run" <"$req" >"$res"
assert_usage

# Codex keeps relative credential paths in the caller's directory.
cat >"$tmp/auth.json" <<'EOF'
{"auth_mode":"chatgpt","tokens":{"access_token":"test-token","account_id":"test-account"}}
EOF
(builtin cd -- "$tmp" && CODEX_HOME=. zsh -f "$codex_run" <"$tmp/codex-request.json" >"$res")
assert_usage

# Provider failures retain streamed text but never complete the response.
typeset event expected
for event expected in \
  '{"type":"response.failed","response":{"error":{"code":"server_error","message":"Please retry"}}}' \
  'response.failed: server_error: Please retry' \
  '{"type":"error","code":"server_error","message":"Please retry"}' \
  'error: server_error: Please retry' \
  '{"type":"response.failed","response":{"error":null}}' \
  'response.failed (no error details)' \
  '{"type":"error"}' \
  'error (no error details)'; do
  print -rl -- 'data: {"type":"response.output_text.delta","delta":"partial"}' \
    "data: $event" >"$BACKEND_TEST_RESPONSE"
  if OPENAI_API_KEY=test zsh -f "$run" <"$req" >"$res" 2>"$tmp/error"; then
    fail 'provider failure was accepted'
  fi
  grep -Fq -- "$expected" "$tmp/error" || fail 'provider failure details were lost'
  jq -e -s '. == [{type:"_assistant_message_delta",index:0,text:"partial"}]' "$res" >/dev/null
done

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
OPENAI_API_KEY=test zsh -f "$run" <"$req" >"$res"
jq -e -s -L "$ROOT" '
  include "lib/runtime/schema";
  include "lib/request";
  assemble_backend_parts(canonical_backend_response_events; canonical_assistant_message) as $parts |
  ($parts.message.stop == "tool_calls") and
  ($parts.message.content == [{type:"reasoning",text:"why",opaque:{type:"reasoning",id:"rs_1",summary:[{type:"summary_text",text:"why"}],encrypted_content:"secret"}}]) and
  ($parts.calls == [{type:"tool_call",id:"call_1",name:"shell",input:{command:"pwd"}}])
' "$res" >/dev/null

# A flat call batch maps one item per record, which this API takes directly.
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
  "options": {"request":{"model":"gpt-test"}},
  "transport": {"endpoint":"https://api.openai.test","insecure_tls":false,"http_timeout":30,"http_stall":10}
}
JSON
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":1,"output_tokens":1}}
EOF
OPENAI_API_KEY=test zsh -f "$run" <"$batch_request" >"$res"
jq -e '
  (.input | map(.type)) ==
    ["message","message","function_call","function_call_output","function_call","function_call_output"] and
  (.input | map(.call_id) | map(select(. != null))) ==
    ["call_1","call_1","call_2","call_2"] and
  .input[2].arguments == "{\"command\":\"pwd\"}"
' "$BACKEND_TEST_BODY" >/dev/null || fail 'responses did not map a flat call batch'
