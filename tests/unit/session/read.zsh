#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp session-read

# Views read the transcript below the session header.
load() { jq -L "$ROOT" -ce 'include "lib/session/read"; session_load'; }
run() { jq -L "$ROOT" -ce 'include "lib/session/read"; session_run'; }
messages() { jq -L "$ROOT" -ce 'include "lib/session/read"; session_messages'; }

typeset records="$tmp/records.jsonl"
cat >"$records" <<'JSONL'
{"type":"system","content":"system text"}
{"type":"hook_result","lifecycle":"session_start","id":"1","name":"env","input":"","executable":"/hooks/env/run","exit_code":0,"user_text":"env","model_text":"<hook name=\"session_start\">\n<context script=\"env\">ready &amp; set</context>\n</hook>"}
{"type":"user","content":[{"type":"text","text":"run it"}]}
{"type":"assistant","stop":"tool_calls","content":[{"type":"reasoning","text":"think","opaque":{"signature":"abc"}},{"type":"text","text":"Inspecting that."},{"type":"tool_call","id":"call_1","name":"shell","input":{"command":"ls"}},{"type":"tool_call","id":"call_2","name":"shell","input":{"command":"pwd"}}],"usage":{"input_tokens":100,"output_tokens":20}}
{"type":"hook_result","lifecycle":"pre_tool_use","id":"2","name":"policy","input":{"turn_id":1,"tool_name":"shell","tool_use_id":"call_1","tool_input":{"command":"ls"}},"exit_code":0,"model_text":"POLICY"}
{"type":"state","name":"git/identity","value":"first"}
{"type":"tool_result","id":"call_1","name":"shell","input":{"command":"ls"},"executable":"/tools/shell/run","exit_code":0,"user_text":"shell\nout","model_text":"out"}
{"type":"tool_result","id":"call_2","name":"shell","input":{"command":"pwd"},"exit_code":0,"model_text":"/tmp"}
{"type":"assistant","stop":"end","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":120,"output_tokens":4}}
JSONL

prefix() { head -n $1 "$records" | jq -sc .; }

# Loading returns the original records and accepts every durable prefix.
assert_equal "$(jq -sc . "$records")" "$(jq -sc . "$records" | load)"
integer total=$(wc -l <"$records")
integer index
for (( index = 1; index <= total; index += 1 )); do
  prefix $index | load >/dev/null || fail "durable prefix of $index records was rejected"
done

# Hook context waits for the request that consumes it.
prefix 2 | run | jq -e '
  .next == "user" and .calls == [] and
  .context == ["<hook name=\"session_start\">\n<context script=\"env\">ready &amp; set</context>\n</hook>"]
' >/dev/null || fail 'session hook context is not pending before the user request'
prefix 3 | run |
  jq -e '. == {next:"assistant",calls:[],context:[]}' >/dev/null ||
  fail 'the user request did not consume pending context'

# Pending calls come from assistant content, in order, and settle one by one.
prefix 4 | run | jq -e '
  .next == "tool_result" and .context == [] and
  .calls == [{id:"call_1",name:"shell",input:{command:"ls"}},
             {id:"call_2",name:"shell",input:{command:"pwd"}}]
' >/dev/null || fail 'pending calls do not follow assistant content'
prefix 6 | run | jq -e '
  .next == "tool_result" and .context == ["POLICY"] and ([.calls[].id] == ["call_1","call_2"])
' >/dev/null || fail 'tool hook context or pending calls are wrong before a result'
prefix 7 | run | jq -e '
  .next == "tool_result" and .context == [] and ([.calls[].id] == ["call_2"])
' >/dev/null || fail 'a settled result did not consume its call and context'
prefix 8 | run | jq -e '. == {next:"assistant",calls:[],context:[]}' >/dev/null ||
  fail 'settling every call did not continue the turn'
prefix 9 | run | jq -e '. == {next:"user",calls:[],context:[]}' >/dev/null ||
  fail 'a complete response did not close the turn'

# Provider messages carry calls, drop usage, and place context where it applied.
jq -sc . "$records" | messages | jq -e '
  [.[].type] == ["user","assistant","tool_call","tool_result","tool_call","tool_result","assistant"] and
  (.[0].content[0].text | startswith("<hook name=\"session_start\">")) and
  (.[0].content[0].text | endswith("\n\nrun it")) and
  (.[1] | has("usage") | not) and
  .[1].content == [{type:"reasoning",text:"think",opaque:{signature:"abc"}},
                   {type:"text",text:"Inspecting that."}] and
  .[2] == {type:"tool_call",id:"call_1",name:"shell",input:{command:"ls"}} and
  .[3] == {type:"tool_result",call_id:"call_1",name:"shell",exit_code:0,
           content:"POLICY\n\nout"} and
  .[5].content == "/tmp" and
  .[6] == {type:"assistant",stop:"end",content:[{type:"text",text:"done"}]}
' >/dev/null || fail 'provider messages do not match the transcript'

# Errors close a turn, reach no request, and never become context.
typeset failed_turn='[
  {"type":"user","content":[{"type":"text","text":"first"}]},
  {"type":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"c1","name":"shell","input":{}}]},
  {"type":"error","user_text":"Backend exited before completing a response."},
  {"type":"user","content":[{"type":"text","text":"second"}]}
]'
print -r -- "$failed_turn" | load >/dev/null || fail 'an error did not close the open turn'
print -r -- "$failed_turn" | run |
  jq -e '. == {next:"assistant",calls:[],context:[]}' >/dev/null ||
  fail 'an error left calls or context pending'
print -r -- "$failed_turn" | messages | jq -e '
  [.[].type] == ["user","user"] and .[1].content[0].text == "second"
' >/dev/null || fail 'an error or its unsettled calls reached the request'

# A cancelled response keeps only complete text and reasoning.
print -r -- '[
  {"type":"user","content":[{"type":"text","text":"stop"}]},
  {"type":"assistant","stop":"cancelled","content":[{"type":"text","text":"partial"}]},
  {"type":"error","user_text":"Cancelled."}
]' | run | jq -e '.next == "user"' >/dev/null ||
  fail 'a cancelled response did not close the turn'

# Trailing context waits for the next real user request.
print -r -- '[
  {"type":"user","content":[{"type":"text","text":"go"}]},
  {"type":"assistant","stop":"end","content":[]},
  {"type":"hook_result","lifecycle":"stop","id":"1","name":"observe","input":"","exit_code":0,"model_text":"NOTE"}
]' | messages | jq -e '
  [.[].type] == ["user","assistant","user"] and .[2].content[0].text == "NOTE"
' >/dev/null || fail 'unconsumed context did not reach the request'

# Stop feedback continues the turn with a request that consumes its context.
print -r -- '[
  {"type":"user","content":[{"type":"text","text":"go"}]},
  {"type":"assistant","stop":"end","content":[]},
  {"type":"hook_result","lifecycle":"stop","id":"1","name":"observe","input":"","exit_code":2,"model_text":"KEEP GOING"}
]' | run | jq -e '. == {next:"assistant",calls:[],context:["KEEP GOING"]}' >/dev/null ||
  fail 'stop feedback did not continue the turn'

# Invalid input fails instead of returning partial state.
typeset -a invalid=(
  'unknown record type' '[{"type":"mystery"}]'
  'unknown stop reason' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"refusal","content":[]}]'
  'tool_calls without a call' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"a"}]}]'
  'a call under another stop' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"end","content":[{"type":"tool_call","id":"c1","name":"shell","input":{}}]}]'
  'a call in a cancelled response' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"cancelled","content":[{"type":"tool_call","id":"c1","name":"shell","input":{}}]}]'
  'repeated call identifiers' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"tool_calls","content":[
       {"type":"tool_call","id":"c1","name":"shell","input":{}},
       {"type":"tool_call","id":"c1","name":"shell","input":{"command":"ls"}}]}]'
  'a result without a call' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"tool_result","id":"c1","name":"shell","input":{},"exit_code":0}]'
  'a result settled out of order' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"tool_calls","content":[
       {"type":"tool_call","id":"c1","name":"shell","input":{}},
       {"type":"tool_call","id":"c2","name":"shell","input":{}}]},
     {"type":"tool_result","id":"c2","name":"shell","input":{},"exit_code":0}]'
  'a result restating its input' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"tool_calls","content":[
       {"type":"tool_call","id":"c1","name":"shell","input":{"command":"ls","request_sandbox_bypass":true}}]},
     {"type":"tool_result","id":"c1","name":"shell","input":{"command":"ls"},"exit_code":0}]'
  'a result without an exit code' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"tool_calls","content":[
       {"type":"tool_call","id":"c1","name":"shell","input":{}}]},
     {"type":"tool_result","id":"c1","name":"shell","input":{}}]'
  'a relative executable' '[{"type":"hook_result","lifecycle":"stop","id":"1","name":"observe",
     "input":"","executable":"hooks/observe","exit_code":0}]'
  'a hook without a lifecycle' '[{"type":"hook_result","id":"1","name":"observe","input":"","exit_code":0}]'
  'an unknown hook lifecycle' '[{"type":"hook_result","lifecycle":"other","id":"1","name":"observe","input":"","exit_code":0}]'
  'a nondecimal hook identifier' '[{"type":"hook_result","lifecycle":"stop","id":"first","name":"observe","input":"","exit_code":0}]'
  'a zero hook identifier' '[{"type":"hook_result","lifecycle":"stop","id":"0","name":"observe","input":"","exit_code":0}]'
  'a repeated hook identifier' '[
     {"type":"hook_result","lifecycle":"session_start","id":"1","name":"env","input":"","exit_code":0},
     {"type":"hook_result","lifecycle":"stop","id":"1","name":"observe","input":"","exit_code":0}]'
  'an empty error' '[{"type":"error","user_text":""}]'
  'an error carrying model text' '[{"type":"error","user_text":"failed","model_text":"failed"}]'
  'reasoning with an extra field' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"end","content":[{"type":"reasoning","text":"why","extra":true}]}]'
  'consecutive user requests' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"user","content":[{"type":"text","text":"b"}]}]'
  'a user request during a tool sequence' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"assistant","stop":"tool_calls","content":[
       {"type":"tool_call","id":"c1","name":"shell","input":{}}]},
     {"type":"user","content":[{"type":"text","text":"b"}]}]'
  'a response without a request' '[{"type":"assistant","stop":"end","content":[]}]'
  'an invalid prefix under a valid tail' '[{"type":"user","content":[{"type":"text","text":"a"}]},
     {"type":"user","content":[{"type":"text","text":"b"}]},
     {"type":"assistant","stop":"end","content":[]}]'
)
for (( index = 1; index <= ${#invalid}; index += 2 )); do
  if print -r -- "$invalid[index + 1]" | load >/dev/null 2>&1; then
    fail "the reader accepted $invalid[index]"
  fi
done

# Settled results share one base, and state names stay addressable.
settling() {
  print -r -- '[{"type":"user","content":[{"type":"text","text":"a"}]},
    {"type":"assistant","stop":"tool_calls","content":[
      {"type":"tool_call","id":"c1","name":"shell","input":{}}]},'"$1"']'
}

settling '{"type":"tool_result","id":"c1","name":"shell","input":{},"executable":"/tools/shell/run","user_text":"shown","model_text":"out","exit_code":0}' |
  load >/dev/null || fail 'the reader rejected a fully described tool result'

typeset -a malformed_results=(
  'an out-of-range exit code' '{"type":"tool_result","id":"c1","name":"shell","input":{},"exit_code":256}'
  'raw capture fields' '{"type":"tool_result","id":"c1","name":"shell","input":{},"stdout":"out","stderr":"","exit_code":0}'
  'a result without input' '{"type":"tool_result","id":"c1","name":"shell","content":"out","exit_code":0}'
  'a hook lifecycle on a tool result' '{"type":"tool_result","id":"c1","name":"shell","input":{},"exit_code":0,"lifecycle":"stop"}'
)
for (( index = 1; index <= ${#malformed_results}; index += 2 )); do
  if settling "$malformed_results[index + 1]" | load >/dev/null 2>&1; then
    fail "the reader accepted $malformed_results[index]"
  fi
done

typeset -a shapes=(
  '{"type":"hook_result","lifecycle":"session_start","id":"1","name":"add_env","input":"","executable":"/hooks/add_env","user_text":"shown","model_text":"data","exit_code":0}'
  '{"type":"hook_result","lifecycle":"pre_tool_use","id":"2","name":"check","input":{},"exit_code":0}'
  '{"type":"state","name":"a","value":null}'
  '{"type":"state","name":"A0_.:/-","value":[false,1,"text"]}'
)
for (( index = 1; index <= ${#shapes}; index += 1 )); do
  print -r -- "[$shapes[index]]" | load >/dev/null ||
    fail "the reader rejected $shapes[index]"
done

typeset -a malformed=(
  'a hook without input' '{"type":"hook_result","lifecycle":"session_start","id":"1","name":"add_env","exit_code":0}'
  'array hook input' '{"type":"hook_result","lifecycle":"session_start","id":"1","name":"add_env","input":[],"exit_code":0}'
  'a tool identifier on a hook' '{"type":"hook_result","lifecycle":"session_start","id":"1","name":"add_env","input":"","exit_code":0,"tool_use_id":"c1"}'
  'empty hook user text' '{"type":"hook_result","lifecycle":"session_start","id":"1","name":"add_env","input":"","exit_code":0,"user_text":""}'
  'an unnamed state record' '{"type":"state","name":"","value":null}'
  'a state name opening with a separator' '{"type":"state","name":"/leading","value":null}'
  'a spaced state name' '{"type":"state","name":"bad name","value":null}'
  'a state record without a value' '{"type":"state","name":"name"}'
)
for (( index = 1; index <= ${#malformed}; index += 2 )); do
  if print -r -- "[$malformed[index + 1]]" | load >/dev/null 2>&1; then
    fail "the reader accepted $malformed[index]"
  fi
done

print -r -- "[$(jq -cn --arg name "$(printf 'a%.0s' {1..128})" \
  '{type:"state",name:$name,value:true}')]" | load >/dev/null ||
  fail 'the reader rejected a state name of the maximum length'
if print -r -- "[$(jq -cn --arg name "$(printf 'a%.0s' {1..129})" \
    '{type:"state",name:$name,value:true}')]" | load >/dev/null 2>&1; then
  fail 'the reader accepted an overlong state name'
fi
