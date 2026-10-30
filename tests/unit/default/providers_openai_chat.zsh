#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

sf_test_tmp providers-openai-chat
typeset run="$ROOT/share/providers/openai_chat/run"
typeset openrouter_run="$ROOT/share/providers/openrouter/run"
typeset context_window="$ROOT/share/providers/openai_chat/context_window"
typeset responses_context_window="$ROOT/share/providers/openai_responses/context_window"
typeset req="$tmp/request.json"
typeset res="$tmp/response.json"
typeset body="$tmp/body.json"

cat >"$tmp/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$PROVIDER_TEST_ARGS"
while (($#)); do
  case $1 in
    --data-binary) cp "${2#@}" "$PROVIDER_TEST_BODY" ; shift 2 ;;
    --header)
      [[ $2 != @* ]] || cp "${2#@}" "$PROVIDER_TEST_HEADERS"
      shift 2 ;;
    *) shift ;;
  esac
done
cat "$PROVIDER_TEST_RESPONSE"
printf "200" >&2
EOF
chmod +x "$tmp/curl"

export PATH="$tmp:$PATH"
export PROVIDER_TEST_BODY="$body"
export PROVIDER_TEST_HEADERS="$tmp/headers"
export PROVIDER_TEST_RESPONSE="$tmp/sse.txt"
export PROVIDER_TEST_ARGS="$tmp/curl-args"

# Assemble fragmented tool calls.
printf "%s\n" \
  'data: {"choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{"content":"Let me "},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{"content":"check."},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"shell","arguments":"{\"command\":"}}]},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"pwd\"}"}}]},"finish_reason":null}]}' \
  'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}' \
  'data: {"choices":[],"usage":{"prompt_tokens":10,"prompt_tokens_details":{"cached_tokens":8},"completion_tokens":5,"completion_tokens_details":{"reasoning_tokens":2},"total_tokens":15}}' \
  'data: [DONE]' \
  "" >"$PROVIDER_TEST_RESPONSE"

cat >"$req" <<'EOF'
{
  "format_version": 1,
  "config": {"http_timeout":60,"http_stall":10,"insecure_tls":true},
  "system": "test system",
  "messages": [
    {"type":"user","content":[{"type":"text","text":"where are we?"}]}
  ],
  "tools": [
    {"name":"shell","description":"run shell","input_schema":{"type":"object","properties":{"command":{"type":"string"}}}}
  ],
  "request":{"model":"gpt-4o","max_tokens":10,"max_completion_tokens":99,
    "max_output_tokens":77,
    "reasoning":{"effort":"medium"},"reasoning_effort":"low",
    "response_format":{"type":"json_object"},
    "response_schema":{"type":"object","required":["answer"],"properties":{"answer":{"type":"string"}}}},
  "endpoint":"https://api.openai.com/v1/chat/completions"
}
EOF

(builtin cd -- "$tmp" && OPENAI_API_KEY=test-key zsh -f "$run" <"$req" >"$res")
assert_equal 60 "$(awk '/^--max-time$/{getline; print; exit}' "$PROVIDER_TEST_ARGS")"
assert_equal 10 "$(awk '/^--speed-time$/{getline; print; exit}' "$PROVIDER_TEST_ARGS")"
grep -Fx -- '--insecure' "$PROVIDER_TEST_ARGS" >/dev/null
jq -e 'has("config") or has("http_timeout") or has("http_stall") or has("insecure_tls") | not' \
  "$PROVIDER_TEST_BODY" >/dev/null || fail 'provider config reached the provider API'

# Use OpenRouter credentials.
(builtin cd -- "$tmp" && OPENROUTER_API_KEY=router-key zsh -f "$openrouter_run" \
  <"$req" >"$res")
grep -Fx 'Authorization: Bearer router-key' "$PROVIDER_TEST_HEADERS" >/dev/null
jq -e '
  (.response_schema | not) and .max_completion_tokens == 77 and
  .reasoning_effort == "low" and
  .response_format == {type:"json_schema",json_schema:{name:"shellfish_response",
    strict:true,schema:{type:"object",required:["answer"],
      properties:{answer:{type:"string"}}}}}
' "$PROVIDER_TEST_BODY" >/dev/null || fail 'openai_chat did not normalize common request parameters'

sf_test_provider_response "$res" || fail 'openai_chat emitted an invalid call stream'
jq -e '
  .stop == "tool_calls" and
  .content == [{type:"text",text:"Let me check."},
    {type:"tool_call",id:"call_123",name:"shell",input:{command:"pwd"}}] and
  .usage == {input_tokens:10,cached_tokens:8,output_tokens:5,reasoning_tokens:2}
' <<<"$REPLY" >/dev/null || fail 'openai_chat did not assemble fragmented calls'
jq -e -s 'map(select(.type == "_assistant_message_delta") | .text) == ["Let me ","check."]' \
  "$res" >/dev/null || fail 'openai_chat did not stream text deltas'

# Normalize model catalog limits.
cat >"$PROVIDER_TEST_RESPONSE" <<'EOF'
{"data":[{"id":"other","context_length":1000},{"id":"gpt-4o","context_length":128000}]}
EOF
(builtin cd -- "$tmp" && OPENAI_API_KEY=test-key zsh -f "$context_window" <"$req" >"$res")
jq -e '. == {context_window:128000}' "$res" >/dev/null
grep -qx 'https://api.openai.com/v1/models' "$PROVIDER_TEST_ARGS"
grep -qx '10' "$PROVIDER_TEST_ARGS"
assert_equal 5 "$(awk '/^--speed-time$/{getline; print; exit}' "$PROVIDER_TEST_ARGS")"
grep -Fx -- '--insecure' "$PROVIDER_TEST_ARGS" >/dev/null
jq '.config={http_timeout:2,http_stall:1,insecure_tls:false}' "$req" >"$tmp/short-request.json"
(builtin cd -- "$tmp" && OPENAI_API_KEY=test-key zsh -f "$context_window" \
  <"$tmp/short-request.json" >"$res")
assert_equal 2 "$(awk '/^--max-time$/{getline; print; exit}' "$PROVIDER_TEST_ARGS")"
assert_equal 1 "$(awk '/^--speed-time$/{getline; print; exit}' "$PROVIDER_TEST_ARGS")"
if grep -Fx -- '--insecure' "$PROVIDER_TEST_ARGS" >/dev/null; then
  fail 'explicit false disabled TLS verification'
fi

jq '.endpoint = "https://api.openai.com/v1/responses"' "$req" >"$tmp/responses-request.json"
(builtin cd -- "$tmp" && OPENAI_API_KEY=test-key zsh -f "$responses_context_window" \
  <"$tmp/responses-request.json" >"$res")
jq -e '. == {context_window:128000}' "$res" >/dev/null
grep -qx 'https://api.openai.com/v1/models' "$PROVIDER_TEST_ARGS"

cat >"$PROVIDER_TEST_RESPONSE" <<'EOF'
{"data":[{"id":"gpt-4o"}]}
EOF
if OPENAI_API_KEY=test-key zsh -f "$context_window" <"$req" >"$res"; then
  fail 'missing model context was reported as available'
fi

# Discard calls stopped by length.
printf "%s\n" \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_cut","function":{"name":"shell","arguments":"{\"command\":"}}]},"finish_reason":"length"}]}' \
  'data: [DONE]' \
  "" >"$PROVIDER_TEST_RESPONSE"
OPENAI_API_KEY=test-key zsh -f "$run" <"$req" >"$res"
sf_test_provider_response "$res" || fail 'openai_chat emitted an invalid length stream'
jq -e '. == {type:"assistant",stop:"length",content:[]}' <<<"$REPLY" >/dev/null ||
  fail 'openai_chat kept calls stopped by length'

# Supply missing call identifiers.
printf "%s\n" \
  'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"shell","arguments":"{}"}}]},"finish_reason":"stop"}]}' \
  'data: [DONE]' \
  "" >"$PROVIDER_TEST_RESPONSE"

OPENAI_API_KEY=test-key zsh -f "$run" <"$req" >"$res"

sf_test_provider_response "$res" || fail 'openai_chat emitted an invalid unnamed-call stream'
jq -e '.stop == "tool_calls" and .content == [{type:"tool_call",id:"call_0",name:"shell",input:{}}]' \
  <<<"$REPLY" >/dev/null || fail 'openai_chat did not supply a missing call identifier'

# Parse buffered JSON responses.
cat >"$PROVIDER_TEST_RESPONSE" <<'EOF'
{
  "id": "chatcmpl-1",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "ok",
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

sf_test_provider_response "$res" || fail 'openai_chat emitted an invalid buffered stream'
jq -e '
  .stop == "tool_calls" and
  .content == [{type:"text",text:"ok"},
    {type:"tool_call",id:"call_abc",name:"shell",input:{command:"ls"}}] and
  .usage == {input_tokens:12,output_tokens:8}
' <<<"$REPLY" >/dev/null || fail 'openai_chat did not parse a buffered response'

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
  "request":{"model":"gpt-test"},
  "endpoint":"https://api.openai.com/v1/chat/completions"
}
JSON
printf '%s\n' 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}' \
  'data: [DONE]' "" >"$PROVIDER_TEST_RESPONSE"
OPENAI_API_KEY=test-key zsh -f "$run" <"$batch_request" >"$res"
jq -e '
  (.messages | map(.role)) == ["system","user","assistant","tool","tool"] and
  .messages[2].content == "working" and
  (.messages[2].tool_calls | map(.id)) == ["call_1","call_2"] and
  .messages[2].tool_calls[0].function == {name:"shell",arguments:"{\"command\":\"pwd\"}"} and
  (.messages | map(.tool_call_id) | map(select(. != null))) == ["call_1","call_2"]
' "$PROVIDER_TEST_BODY" >/dev/null || fail 'openai_chat did not regroup a call batch'

# Tool result images.
jq -c '.messages[3].content = [{type:"text",text:"shot"},
  {type:"image",url:"data:image/png;base64,iVBORw0KGgo="}] |
  .messages[5].content = [{type:"image",url:"data:image/png;base64,iVBORw0KGgo="}]' \
  "$batch_request" >"$tmp/images.json"
# Tool messages keep their text, and one user message after the batch carries the images.
jq -c '.messages += [{type:"user",content:[{type:"text",text:"next"}]}]' \
  "$tmp/images.json" >"$tmp/images-next.json"
OPENAI_API_KEY=test-key zsh -f "$run" <"$tmp/images-next.json" >"$res"
jq -e '
  (.messages | map(.role)) == ["system","user","assistant","tool","tool","user","user"] and
  (.messages[3:5] | map(.content)) == ["shot","[images follow in the next user message]"] and
  .messages[5].content == [
    {type:"text",text:"Images from the shell call call_1:"},
    {type:"image_url",image_url:{url:"data:image/png;base64,iVBORw0KGgo="}},
    {type:"text",text:"Images from the shell call call_2:"},
    {type:"image_url",image_url:{url:"data:image/png;base64,iVBORw0KGgo="}}] and
  .messages[6].content == "next"
' "$PROVIDER_TEST_BODY" >/dev/null || fail 'openai_chat did not lift tool result images'

# Encode call-only messages as null.
jq -c '.messages[1].content = []' "$batch_request" >"$tmp/calls-only.json"
OPENAI_API_KEY=test-key zsh -f "$run" <"$tmp/calls-only.json" >"$res"
jq -e '.messages[2].content == null and (.messages[2].tool_calls | length) == 2'   "$PROVIDER_TEST_BODY" >/dev/null || fail 'a call-only message did not send null content'

# The provider always streams, so a stream option is refused.
jq -c '.request.stream = false' "$req" >"$tmp/no-stream.json"
if OPENAI_API_KEY=test zsh -f "$run" <"$tmp/no-stream.json" >"$res" 2>"$tmp/error"; then
  fail 'openai_chat accepted a stream option'
fi
grep -Fq -- 'invalid request' "$tmp/error" || fail 'openai_chat did not explain the refused stream option'
