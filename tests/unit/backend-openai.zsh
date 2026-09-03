#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_source backend.zsh

sf_test_tmp backend-openai
typeset run="$ROOT/default/backends/openai/run"
typeset context_window="$ROOT/default/backends/openai/context_window"
typeset responses_context_window="$ROOT/default/backends/openai-responses/context_window"
typeset req="$tmp/request.json"
typeset res="$tmp/response.json"
typeset body="$tmp/body.json"

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

SHELLFISH_API_KEY=test-key zsh -f "$run" <"$req" >"$res"

jq -n -e -L "$ROOT/lib" '
  include "runtime/schema";
  [inputs] | assemble_backend_response |
  canonical_assistant_message and
  .role == "assistant" and
  .stop == "tool_calls" and
  .content[0] == {type:"text",text:"Let me check."} and
  .content[1] == {type:"tool_call",id:"call_123",name:"shell",input:{command:"pwd"}} and
  .usage.input_tokens == 10 and
  .usage.cached_tokens == 8 and
  .usage.output_tokens == 5 and
  .usage.reasoning_tokens == 2
' "$res" >/dev/null

# Model metadata normalizes OpenRouter's catalog field without affecting generation.
cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"data":[{"id":"other","context_length":1000},{"id":"gpt-4o","context_length":128000}]}
EOF
SHELLFISH_API_KEY=test-key zsh -f "$context_window" <"$req" >"$res"
jq -e '. == {context_window:128000}' "$res" >/dev/null
grep -qx 'https://api.openai.com/v1/models' "$BACKEND_TEST_ARGS"
grep -qx '10' "$BACKEND_TEST_ARGS"

jq '.transport.endpoint = "https://api.openai.com/v1/responses"' "$req" >"$tmp/responses-request.json"
SHELLFISH_API_KEY=test-key zsh -f "$responses_context_window" \
  <"$tmp/responses-request.json" >"$res"
jq -e '. == {context_window:128000}' "$res" >/dev/null
grep -qx 'https://api.openai.com/v1/models' "$BACKEND_TEST_ARGS"

cat >"$BACKEND_TEST_RESPONSE" <<'EOF'
{"data":[{"id":"gpt-4o"}]}
EOF
if SHELLFISH_API_KEY=test-key zsh -f "$context_window" <"$req" >"$res"; then
  fail 'missing model context was reported as available'
fi

# A length stop discards partial tool state rather than completing a call.
printf "%s\n" \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_cut","function":{"name":"shell","arguments":"{\"command\":"}}]},"finish_reason":"length"}]}' \
  'data: [DONE]' \
  "" >"$BACKEND_TEST_RESPONSE"
SHELLFISH_API_KEY=test-key zsh -f "$run" <"$req" >"$res"
jq -n -e -L "$ROOT/lib" '
  include "runtime/schema";
  [inputs] | assemble_backend_response ==
    {type:"message",role:"assistant",stop:"length",content:[]}
' "$res" >/dev/null

# 2. Test compatible backend sending finish_reason: "stop" or missing id on tool calls
printf "%s\n" \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"shell","arguments":"{}"}}]},"finish_reason":"stop"}]}' \
  'data: [DONE]' \
  "" >"$BACKEND_TEST_RESPONSE"

SHELLFISH_API_KEY=test-key zsh -f "$run" <"$req" >"$res"

jq -n -e -L "$ROOT/lib" '
  include "runtime/schema";
  [inputs] | assemble_backend_response |
  canonical_assistant_message and
  .stop == "tool_calls" and
  .content[0].type == "tool_call" and
  .content[0].name == "shell" and
  .content[0].id == "call_0" and
  .content[0].input == {}
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

SHELLFISH_API_KEY=test-key zsh -f "$run" <"$req" >"$res"

jq -n -e -L "$ROOT/lib" '
  include "runtime/schema";
  [inputs] | assemble_backend_response |
  canonical_assistant_message and
  .stop == "tool_calls" and
  .content[0] == {type:"tool_call",id:"call_abc",name:"shell",input:{command:"ls"}} and
  .usage.input_tokens == 12 and
  .usage.output_tokens == 8
' "$res" >/dev/null
