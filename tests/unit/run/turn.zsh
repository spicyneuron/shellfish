#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-turn-contract
export SF_TEST_PROVIDER_DELAY=0

# A successful turn appends each durable object before emitting it.
sf_test_frozen_profile
typeset session="$tmp/simple.jsonl" stream="$tmp/simple.stream"
sf_test_session "$session"
integer prefix=$(wc -l <"$session")
sf_test_run $'two\nwords' "$session" >"$stream" || fail 'simple turn failed'
jq -eRn -L "$ROOT" '
  include "lib/session";
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "user" or .type == "assistant"))) as $durable |
  $durable[0] == {type:"user",content:[{type:"text",text:"two\nwords"}]} and
  ($durable[1] | .type == "assistant" and .stop == "end" and
    (.usage | token_usage)) and
  ($events | any(.type == "_assistant_message_delta"))
' <"$stream" >/dev/null || fail 'simple turn emitted the wrong objects'
jq -c 'select(.type | startswith("_") | not)' "$stream" >"$tmp/emitted"
tail -n +$(( prefix + 1 )) "$session" | jq -c . >"$tmp/appended"
cmp -s "$tmp/emitted" "$tmp/appended" ||
  fail 'durable events differ from appended records'

# Complete calls execute in assistant order and all settle before continuation.
typeset provider="$tmp/provider/run" tool="$tmp/ordered/run" order="$tmp/order"
mkdir -p "${provider:h}" "${tool:h}"
cat >"$provider" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
if jq -e '.messages | any(.type == "tool_result")' <<<"$request" >/dev/null; then
  jq -e '
    .messages[-4:] == [
      {type:"tool_call",id:"call_1",name:"ordered",input:{value:"first"}},
      {type:"tool_result",call_id:"call_1",name:"ordered",content:"first",exit_code:0},
      {type:"tool_call",id:"call_2",name:"ordered",input:{value:"second"}},
      {type:"tool_result",call_id:"call_2",name:"ordered",content:"second",exit_code:0}
    ]
  ' <<<"$request" >/dev/null || exit 9
  [[ $(<$TOOL_ORDER) == $'first\nsecond' ]] || exit 8
  print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":2,"output_tokens":1}}'
else
  print -r -- '{"type":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"ordered","input":{"value":"first"}},{"type":"tool_call","id":"call_2","name":"ordered","input":{"value":"second"}}],"usage":{"input_tokens":1,"output_tokens":1}}'
fi
ZSH
cat >"$tool" <<'ZSH'
#!/usr/bin/env zsh
value=$(jq -er '.value | select(type == "string")') || exit 2
print -r -- "$value" >>"$TOOL_ORDER"
print -rn -u3 -- "{\"state_update\":[{\"name\":\"tool/$value\",\"value\":true}]}"
print -rn -- "$value"
ZSH
chmod +x "$provider" "$tool"
print -r -- '{
  "description": "Record ordered calls",
  "input_schema": {"type": "object", "additionalProperties": false, "required": ["value"],
    "properties": {"value": {"type": "string"}}},
  "environment": ["TOOL_ORDER"],
  "user_text": "Ordered ${input.value}",
  "sandbox": false
}' >"${tool:h}/manifest.json"
SF_TEST_MODEL=$(jq -c --arg provider "${provider:h}" '.provider=$provider' <<<"$SF_TEST_MODEL")
SF_TEST_PROFILE=$(jq -c --arg tool "${tool:h}" '.tools=[$tool]' <<<"$SF_TEST_PROFILE")
export TOOL_ORDER=$order
session="$tmp/ordered.jsonl"
sf_test_session "$session"
sf_test_run ordered "$session" >"$stream" || fail 'ordered tool turn failed'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type | IN("assistant","_draft","state_update","tool_result")) |
    if .type == "assistant" then [.type,.stop]
    elif .type == "state_update" then [.type,.name]
    else [.type,.id,.name,.exit_code?] end] == [
      ["assistant","tool_calls"],
      ["_draft","call_1","ordered",null],
      ["state_update","tool/first"],
      ["tool_result","call_1","ordered",0],
      ["_draft","call_2","ordered",null],
      ["state_update","tool/second"],
      ["tool_result","call_2","ordered",0],
      ["assistant","end"]
    ] and
  ($events | map(select(.type == "tool_result") | .input)) ==
    [{value:"first"},{value:"second"}] and
  ($events | map(select(.type == "tool_result") | [.user_text,.model_text])) ==
    [["Ordered first","first"],["Ordered second","second"]]
' <"$stream" >/dev/null || fail 'tool calls did not settle in order'
assert_canonical_session "$session"

# Unknown tools and calls beyond the per-request limit settle as denials.
typeset limited_provider="$tmp/limited-provider/run"
mkdir -p "${limited_provider:h}"
cat >"$limited_provider" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
if jq -e '.messages | any(.type == "tool_result")' <<<"$request" >/dev/null; then
  print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":2,"output_tokens":1}}'
else
  print -r -- '{"type":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"missing","input":{}},{"type":"tool_call","id":"call_2","name":"missing","input":{}}],"usage":{"input_tokens":1,"output_tokens":1}}'
fi
ZSH
chmod +x "$limited_provider"
SF_TEST_MODEL=$(jq -c --arg provider "${limited_provider:h}" '.provider=$provider' <<<"$SF_TEST_MODEL")
SF_TEST_PROFILE=$(jq -c '.tools=[]' <<<"$SF_TEST_PROFILE")
session="$tmp/limited.jsonl"
sf_test_session "$session"
SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST=1 sf_test_run limited "$session" >"$stream" ||
  fail 'limited tool turn failed'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")] as $results |
  ($results | length) == 2 and
  $results[0].exit_code == 127 and ($results[0].model_text | contains("not allowed")) and
  $results[1].exit_code == 126 and ($results[1].model_text | contains("limit"))
' <"$stream" >/dev/null || fail 'ordinary tool denials did not settle calls'
assert_canonical_session "$session"

# A failed append ends transcript mutation, including the usual durable error.
typeset break_hook="$tmp/break-session" broken="$tmp/broken.jsonl"
sf_test_hook "$break_hook" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
mv "$SHELLFISH_SESSION" "$SHELLFISH_SESSION.saved" || exit
mkdir "$SHELLFISH_SESSION"
ZSH
sf_test_bind_hooks user_prompt_submit "$break_hook"
sf_test_session "$broken"
integer broken_status=0
sf_test_run broken "$broken" >"$stream" 2>"$tmp/broken.stderr" || broken_status=$?
(( broken_status == 1 )) || fail 'turn continued after its session became unavailable'
[[ -d $broken && -z $(find "$broken" -mindepth 1 -print -quit) ]] ||
  fail 'turn mutated the unavailable session after its first write failure'
jq -es 'length == 1 and .[0].type == "session"' "$broken.saved" >/dev/null ||
  fail 'write failure changed the previously durable prefix'

# A provider receives every .env value; exported values win.
sf_test_frozen_profile
typeset env_provider="$tmp/env-provider/run" env_session="$tmp/env.jsonl"
mkdir -p "${env_provider:h}"
typeset env_config="$SHELLFISH_DIR"
mkdir -p "$env_config"
print -rl -- FILE_SECRET=file-value EXPORTED_SECRET=file-value >"$env_config/.env"
cat >"$env_provider" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
jq -cn --arg text "${FILE_SECRET-unset} ${EXPORTED_SECRET-unset}" \
  '{type:"assistant",stop:"end",content:[{type:"text",text:$text}]}'
ZSH
chmod +x "$env_provider"
SF_TEST_MODEL=$(jq -c --arg provider "${env_provider:h}" '.provider=$provider' <<<"$SF_TEST_MODEL")
export EXPORTED_SECRET=exported-value
sf_test_session "$env_session"
sf_test_run env "$env_session" >"$stream" || fail 'provider environment turn failed'
jq -eRn '[inputs | fromjson | select(.type == "assistant") | .content[0].text] ==
  ["file-value exported-value"]' <"$stream" >/dev/null ||
  fail 'provider did not receive layered environment values'
unset EXPORTED_SECRET

print -r -- ok
