#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh
sf_test_tmp run-turn-contract
export XDG_STATE_HOME="$tmp/state" SF_TEST_BACKEND_DELAY=0

# A successful turn appends each durable object before emitting it.
sf_test_runtime
typeset session="$tmp/simple.jsonl" stream="$tmp/simple.stream"
sf_test_session "$session"
integer prefix=$(wc -l <"$session")
sf_test_run $'two\nwords' "$session" >"$stream" || fail 'simple turn failed'
jq -eRn -L "$ROOT" '
  include "lib/runtime/schema";
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "user" or .type == "assistant"))) as $durable |
  $durable[0] == {type:"user",content:[{type:"text",text:"two\nwords"}]} and
  ($durable[1] | .type == "assistant" and .stop == "end" and
    (.usage | token_usage)) and
  ($events | any(.type == "_assistant_message_delta")) and
  ($events | any(.type == "_turn_usage"))
' <"$stream" >/dev/null || fail 'simple turn emitted the wrong objects'
jq -c 'select(.type | startswith("_") | not)' "$stream" >"$tmp/emitted"
tail -n +$(( prefix + 1 )) "$session" | jq -c . >"$tmp/appended"
cmp -s "$tmp/emitted" "$tmp/appended" ||
  fail 'durable events differ from appended records'

# Complete calls execute in assistant order and all settle before continuation.
typeset backend="$tmp/backend" tool="$tmp/tool" order="$tmp/order"
cat >"$backend" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
if jq -e '.messages | any(.type == "tool_result")' <<<"$request" >/dev/null; then
  jq -e '
    .messages[-4:] == [
      {type:"tool_call",id:"call_1",name:"ordered",input:{value:"first"}},
      {type:"tool_result",call_id:"call_1",name:"ordered",content:"first\nexit 0",exit_code:0},
      {type:"tool_call",id:"call_2",name:"ordered",input:{value:"second"}},
      {type:"tool_result",call_id:"call_2",name:"ordered",content:"second\nexit 0",exit_code:0}
    ]
  ' <<<"$request" >/dev/null || exit 9
  [[ $(<$TOOL_ORDER) == $'first\nsecond' ]] || exit 8
  print -r -- '{"type":"_assistant_message_delta","index":0,"text":"done"}'
  print -r -- '{"type":"_turn_usage","input_tokens":2,"output_tokens":1}'
  print -r -- '{"type":"_assistant_end","stop":"end"}'
else
  print -r -- '{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"ordered","input":"{\"value\":\"first\"}"}'
  print -r -- '{"type":"_assistant_tool_call_delta","index":1,"id":"call_2","name":"ordered","input":"{\"value\":\"second\"}"}'
  print -r -- '{"type":"_turn_usage","input_tokens":1,"output_tokens":1}'
  print -r -- '{"type":"_assistant_end","stop":"tool_calls"}'
fi
ZSH
cat >"$tool" <<'ZSH'
#!/usr/bin/env zsh
value=$(jq -er '.value | select(type == "string")') || exit 2
print -r -- "$value" >>"$TOOL_ORDER"
print -rn -- "$value"
ZSH
chmod +x "$backend" "$tool"
SF_TEST_RUNTIME=$(jq -c --arg backend "$backend" --arg tool "$tool" '
  .backend.command=$backend | .backend.environment=["TOOL_ORDER"] |
  .harness.tools=[{
    name:"ordered",command:$tool,settings:null,
    manifest:{
      description:"Record ordered calls",
      input_schema:{type:"object",additionalProperties:false,required:["value"],
        properties:{value:{type:"string"}}},
      render:{
        running:"${name}\n${input}",
        user:"${name}\n${output.stdout}${output.stderr}\nexit ${output.exit_code}",
        model:"${output.stdout}${output.stderr}\nexit ${output.exit_code}",
        permission:"${input}"
      },
      environment:["TOOL_ORDER"],
      sandbox:false
    }
  }]
' <<<"$SF_TEST_RUNTIME")
export TOOL_ORDER=$order
session="$tmp/ordered.jsonl"
sf_test_session "$session"
sf_test_run ordered "$session" >"$stream" || fail 'ordered tool turn failed'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type | IN("assistant","_tool_activity","tool_result")) |
    if .type == "assistant" then [.type,.stop]
    else [.type,.id,.name,.exit_code?] end] == [
      ["assistant","tool_calls"],
      ["_tool_activity","call_1","ordered",null],
      ["tool_result","call_1","ordered",0],
      ["_tool_activity","call_2","ordered",null],
      ["tool_result","call_2","ordered",0],
      ["assistant","end"]
    ] and
  ($events | map(select(.type == "tool_result") | .input)) ==
    [{value:"first"},{value:"second"}] and
  ($events | map(select(.type == "tool_result") | .model_text)) ==
    ["first\nexit 0","second\nexit 0"]
' <"$stream" >/dev/null || fail 'tool calls did not settle in order'
assert_canonical_session "$session"

# Unknown tools and calls beyond the per-request limit settle as denials.
typeset limited_backend="$tmp/limited-backend"
cat >"$limited_backend" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
if jq -e '.messages | any(.type == "tool_result")' <<<"$request" >/dev/null; then
  print -r -- '{"type":"_assistant_message_delta","index":0,"text":"done"}'
  print -r -- '{"type":"_turn_usage","input_tokens":2,"output_tokens":1}'
  print -r -- '{"type":"_assistant_end","stop":"end"}'
else
  print -r -- '{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"missing","input":"{}"}'
  print -r -- '{"type":"_assistant_tool_call_delta","index":1,"id":"call_2","name":"missing","input":"{}"}'
  print -r -- '{"type":"_turn_usage","input_tokens":1,"output_tokens":1}'
  print -r -- '{"type":"_assistant_end","stop":"tool_calls"}'
fi
ZSH
chmod +x "$limited_backend"
SF_TEST_RUNTIME=$(jq -c --arg backend "$limited_backend" '
  .backend.command=$backend | .harness.tools=[] | .harness.max_tool_calls_per_request=1
' <<<"$SF_TEST_RUNTIME")
session="$tmp/limited.jsonl"
sf_test_session "$session"
sf_test_run limited "$session" >"$stream" || fail 'limited tool turn failed'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")] as $results |
  ($results | length) == 2 and
  $results[0].exit_code == 127 and ($results[0].model_text | contains("not allowed")) and
  $results[1].exit_code == 126 and ($results[1].model_text | contains("limit"))
' <"$stream" >/dev/null || fail 'ordinary tool denials did not settle calls'
assert_canonical_session "$session"

print -r -- ok
