#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

sf_test_tmp backends-openai
typeset run="$ROOT/share/default/backends/openai/run"
typeset openrouter_run="$ROOT/share/default/backends/openrouter/run"
typeset context_window="$ROOT/share/default/backends/openai/context_window"
typeset responses_context_window="$ROOT/share/default/backends/openai-responses/context_window"
typeset req="$tmp/request.json"
typeset res="$tmp/response.json"
typeset body="$tmp/body.json"

# Adapter module lookup must ignore the caller's working tree.
mkdir -p "$tmp/lib/runtime"
print -r -- 'def canonical_request(:' >"$tmp/lib/runtime/schema.jq"

cat >"$tmp/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BACKEND_TEST_ARGS"
while (($#)); do
  case $1 in
    --data-binary) cp "${2#@}" "$BACKEND_TEST_BODY" ; shift 2 ;;
    --header)
      [[ $2 != @* ]] || cp "${2#@}" "$BACKEND_TEST_HEADERS"
      shift 2 ;;
    *) shift ;;
  esac
done
cat "$BACKEND_TEST_RESPONSE"
printf "200" >&2
EOF
chmod +x "$tmp/curl"

export PATH="$tmp:$PATH"
export BACKEND_TEST_BODY="$body"
export BACKEND_TEST_HEADERS="$tmp/headers"
export BACKEND_TEST_RESPONSE="$tmp/sse.txt"
export BACKEND_TEST_ARGS="$tmp/curl-args"

# 1. Test streaming with fragmented tool call, missing type in delta, omitted id in later chunks
printf "%s\n" \
  'data: {"choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{"content":"Let me "},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{"content":"check."},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"shell","arguments":"{\"command\":"}}]},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"pwd\"}"}}]},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}' \
  'data: {"choices":[],"usage":{"prompt_tokens":10,"prompt_tokens_details":{"cached_tokens":8},"completion_tokens":5,"completion_tokens_details":{"reasoning_tokens":2},"total_tokens":15}}' \
  'data: [DONE]' \
  "" >"$BACKEND_TEST_RESPONSE"

cat >"$req" <<'EOF'
{
  "format_version": 1,
  "system": "test system",
  "messages": [
    {"role":"user","content":[{"type":"text","text":"where are we?"}]}
  ],
  "tools": [
    {"name":"shell","description":"run shell","input_schema":{"type":"object","properties":{"command":{"type":"string"}}}}
  ],
  "options":{"request":{"model":"gpt-4o"}},
  "transport":{"endpoint":"https://api.openai.com/v1/chat/completions","insecure_tls":false,"http_timeout":30,"http_stall":10}
}
EOF

(builtin cd -- "$tmp" && OPENAI_API_KEY=test-key zsh -f "$run" <"$req" >"$res")

# OpenRouter owns its user-facing credential name and delegates the protocol.
(builtin cd -- "$tmp" && OPENROUTER_API_KEY=router-key zsh -f "$openrouter_run" \
  <"$req" >"$res")
grep -Fx 'Authorization: Bearer router-key' "$BACKEND_TEST_HEADERS" >/dev/null

jq -n -e -L "$ROOT" '
  include "lib/runtime/schema";
  include "lib/request";
  [inputs] |
  assemble_backend_parts(canonical_backend_response_events; canonical_assistant_message) as $parts |
  ($parts.message | canonical_assistant_message) and
  ($parts.message.role == "assistant") and
  ($parts.message.stop == "tool_calls") and
  ($parts.message.content == [{type:"text",text:"Let me check."}]) and
  ($parts.calls == [{type:"tool_call",id:"call_123",name:"shell",input:{command:"pwd"}}]) and
  ($parts.message.usage.input_tokens == 10) and
  ($parts.message.usage.cached_tokens == 8) and
  ($parts.message.usage.output_tokens == 5) and
  ($parts.message.usage.reasoning_tokens == 2)
' "$res" >/dev/null

# Model metadata normalizes OpenRouter's catalog field without affecting generation.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"data":[{"id":"other","context_length":1000},{"id":"gpt-4o","context_length":128000}]}
EOF
(builtin cd -- "$tmp" && OPENAI_API_KEY=test-key zsh -f "$context_window" <"$req" >"$res")
jq -e '. == {context_window:128000}' "$res" >/dev/null
grep -qx 'https://api.openai.com/v1/models' "$BACKEND_TEST_ARGS"
grep -qx '10' "$BACKEND_TEST_ARGS"

jq '.transport.endpoint = "https://api.openai.com/v1/responses"' "$req" >"$tmp/responses-request.json"
(builtin cd -- "$tmp" && OPENAI_API_KEY=test-key zsh -f "$responses_context_window" \
  <"$tmp/responses-request.json" >"$res")
jq -e '. == {context_window:128000}' "$res" >/dev/null
grep -qx 'https://api.openai.com/v1/models' "$BACKEND_TEST_ARGS"

cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"data":[{"id":"gpt-4o"}]}
EOF
if OPENAI_API_KEY=test-key zsh -f "$context_window" <"$req" >"$res"; then
  fail 'missing model context was reported as available'
fi

# A length stop discards partial tool state rather than completing a call.
printf "%s\n" \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_cut","function":{"name":"shell","arguments":"{\"command\":"}}]},"finish_reason":"length"}]}' \
  'data: [DONE]' \
  "" >"$BACKEND_TEST_RESPONSE"
OPENAI_API_KEY=test-key zsh -f "$run" <"$req" >"$res"
jq -n -e -L "$ROOT" '
  include "lib/runtime/schema";
  include "lib/request";
  [inputs] | assemble_backend_response(canonical_backend_response_events; canonical_assistant_message) ==
    {type:"message",role:"assistant",stop:"length",content:[]}
' "$res" >/dev/null

# 2. Test compatible backend sending finish_reason: "stop" or missing id on tool calls
printf "%s\n" \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"shell","arguments":"{}"}}]},"finish_reason":"stop"}]}' \
  'data: [DONE]' \
  "" >"$BACKEND_TEST_RESPONSE"

OPENAI_API_KEY=test-key zsh -f "$run" <"$req" >"$res"

jq -n -e -L "$ROOT" '
  include "lib/runtime/schema";
  include "lib/request";
  [inputs] |
  assemble_backend_parts(canonical_backend_response_events; canonical_assistant_message) as $parts |
  ($parts.message | canonical_assistant_message) and
  ($parts.message.stop == "tool_calls") and
  ($parts.calls == [{type:"tool_call",id:"call_0",name:"shell",input:{}}])
' "$res" >/dev/null

# 3. Test non-streaming JSON response
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{
  "id": "chatcmpl-1",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "id": "call_abc",
            "type": "function",
            "function": {
              "name": "shell",
              "arguments": "{\"command\":\"ls\"}"
            }
          }
        ]
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 8,
    "total_tokens": 20
  }
}
EOF

OPENAI_API_KEY=test-key zsh -f "$run" <"$req" >"$res"

jq -n -e -L "$ROOT" '
  include "lib/runtime/schema";
  include "lib/request";
  [inputs] |
  assemble_backend_parts(canonical_backend_response_events; canonical_assistant_message) as $parts |
  ($parts.message | canonical_assistant_message) and
  ($parts.message.stop == "tool_calls") and
  ($parts.calls == [{type:"tool_call",id:"call_abc",name:"shell",input:{command:"ls"}}]) and
  ($parts.message.usage.input_tokens == 12) and
  ($parts.message.usage.output_tokens == 8)
' "$res" >/dev/null

# A flat call batch regroups into the shape this provider expects.
typeset batch_request="$tmp/batch-request.json"
cat >"$batch_request" <<'JSON'
{
  "format_version": 1,
  "system": "test",
  "messages": [
    {"role":"user","content":[{"type":"text","text":"run both"}]},
    {"role":"assistant","stop":"tool_calls","content":[{"type":"text","text":"working"}]},
    {"role":"tool_call","id":"call_1","name":"shell","input":{"command":"pwd"}},
    {"role":"tool_result","call_id":"call_1","name":"shell","content":"/tmp","exit_code":0},
    {"role":"tool_call","id":"call_2","name":"shell","input":{"command":"ls"}},
    {"role":"tool_result","call_id":"call_2","name":"shell","content":"bad","exit_code":1}
  ],
  "tools": [],
  "options": {"request":{"model":"gpt-test"}},
  "transport": {"endpoint":"https://api.openai.com/v1/chat/completions","insecure_tls":false,"http_timeout":30,"http_stall":10}
}
JSON
printf '%s\n' 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}' \
  'data: [DONE]' "" >"$BACKEND_TEST_RESPONSE"
OPENAI_API_KEY=test-key zsh -f "$run" <"$batch_request" >"$res"
jq -e '
  (.messages | map(.role)) == ["system","user","assistant","tool","tool"] and
  .messages[2].content == "working" and
  (.messages[2].tool_calls | map(.id)) == ["call_1","call_2"] and
  .messages[2].tool_calls[0].function == {name:"shell",arguments:"{\"command\":\"pwd\"}"} and
  (.messages | map(.tool_call_id) | map(select(. != null))) == ["call_1","call_2"]
' "$BACKEND_TEST_BODY" >/dev/null || fail 'openai did not regroup a call batch'

# A call-only assistant message must send null content, not an empty string.
jq -c '.messages[1].content = []' "$batch_request" >"$tmp/calls-only.json"
OPENAI_API_KEY=test-key zsh -f "$run" <"$tmp/calls-only.json" >"$res"
jq -e '.messages[2].content == null and (.messages[2].tool_calls | length) == 2'   "$BACKEND_TEST_BODY" >/dev/null || fail 'a call-only message did not send null content'
