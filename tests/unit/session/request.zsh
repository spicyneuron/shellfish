#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

fold() {
  jq -L "$ROOT" -c --argjson tools '[{
    "name":"shell",
    "manifest":{"render":{"model_after":"${output.stdout}${output.stderr}"}}
  }]' 'include "lib/render"; include "lib/session/request";
    map(if .type == "tool_result" then
      .content = ({tools:$tools,record:.} | render_tool_model)
    else . end) | request_messages'
}

# Conversation records drop storage fields.
print -r -- '[
  {"type":"session"},
  {"type":"system","content":"ignored"},
  {"type":"user","content":[{"type":"text","text":"hi"}]},
  {"type":"error","user_text":"ignored"},
  {"type":"assistant","content":[],"usage":{"input_tokens":1}}
]' | fold | jq -e '
  . == [{type:"user",content:[{type:"text",text:"hi"}]},
        {type:"assistant",content:[]}]
' >/dev/null

# State and empty context do not split model context.
print -r -- '[
  {"type":"user","content":[{"type":"text","text":"first"}]},
  {"type":"state","name":"before/context","value":1},
  {"type":"hook_result","model_text":"A"},
  {"type":"state","name":"between/context","value":null},
  {"type":"hook_result"},
  {"type":"hook_result","model_text":"B"},
  {"type":"state","name":"before/user","value":{"nested":true}},
  {"type":"user","content":[{"type":"text","text":"second"}]},
  {"type":"state","name":"trailing","value":false}
]' | fold | jq -e '
  length == 2 and .[0].content[0].text == "first" and
  .[1].content[0].text == "A\n\nB\n\nsecond"
' >/dev/null

# Model context prefixes the next user message.
print -r -- '[
  {"type":"hook_result","model_text":"CTX"},
  {"type":"user","content":[{"type":"text","text":"hi"}]}
]' | fold | jq -e '
  (. | length) == 1 and .[0].type == "user" and
  .[0].content[0].text == "CTX\n\nhi"
' >/dev/null

# Adjacent rendered contexts retain order.
print -r -- '[
  {"type":"hook_result","model_text":"one"},
  {"type":"hook_result","model_text":"two"},
  {"type":"hook_result","model_text":"three"},
  {"type":"user","content":[{"type":"text","text":"hi"}]}
]' | fold | jq -e '
  (. | length) == 1 and .[0].content[0].text == "one\n\ntwo\n\nthree\n\nhi"
' >/dev/null

# Markup in a body reaches the model verbatim.
print -r -- '[
  {"type":"hook_result","model_text":"<note>a && b</note>"},
  {"type":"user","content":[{"type":"text","text":"hi"}]}
]' | fold | jq -e '
  .[0].content[0].text == "<note>a && b</note>\n\nhi"
' >/dev/null

# Pending context cannot split a tool pair.
print -r -- '[
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"hook_result","model_text":"CTX"},
  {"type":"tool_result","call_id":"c1","name":"shell",
   "input":{},"stdout":"out","stderr":"err","exit_code":0},
  {"type":"user","content":[{"type":"text","text":"next"}]}
]' | fold | jq -e '
  [.[].type] == ["assistant","tool_call","tool_result","user"] and
  .[1] == {type:"tool_call",id:"c1",name:"shell",input:{}} and
  (.[2] | has("input", "stdout", "stderr") | not) and
  .[2].content == "outerr" and
  .[3].content[0].text == "CTX\n\nnext"
' >/dev/null

# Correlated context surrounds its own tool result in lifecycle order.
print -r -- '[
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"hook_result","tool_use_id":"c1","model_text":"PRE"},
  {"type":"hook_result","tool_use_id":"c1","model_text":"PERMISSION"},
  {"type":"tool_result","call_id":"c1","name":"shell",
   "input":{},"stdout":"out","stderr":"","exit_code":0},
  {"type":"hook_result","tool_use_id":"c1","model_text":"POST"},
  {"type":"user","content":[{"type":"text","text":"next"}]}
]' | fold | jq -e '
  [.[].type] == ["assistant","tool_call","tool_result","user"] and
  .[2].content == "PRE\n\nPERMISSION\n\nout\n\nPOST" and
  .[3].content[0].text == "next"
' >/dev/null

# A reused call ID correlates within its own response.
print -r -- '[
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"tool_result","call_id":"c1","name":"shell",
   "input":{},"stdout":"first","stderr":"","exit_code":0},
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"hook_result","tool_use_id":"c1","model_text":"SECOND PRE"},
  {"type":"tool_result","call_id":"c1","name":"shell",
   "input":{},"stdout":"second","stderr":"","exit_code":0}
]' | fold | jq -e '
  [.[] | select(.type == "tool_result") | .content] == ["first", "SECOND PRE\n\nsecond"]
' >/dev/null

# Correlated context without a settled result is dropped.
print -r -- '[
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"hook_result","tool_use_id":"c1","model_text":"ORPHAN"},
  {"type":"error","user_text":"interrupted"},
  {"type":"user","content":[{"type":"text","text":"next"}]}
]' | fold | jq -e '
  [.[].type] == ["user"] and .[0].content[0].text == "next"
' >/dev/null

# A tool-calling assistant without settled results is omitted.
print -r -- '[
  {"type":"user","content":[{"type":"text","text":"first"}]},
  {"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"orphan"}]},
  {"type":"error","user_text":"interrupted"},
  {"type":"user","content":[{"type":"text","text":"next"}]}
]' | fold | jq -e '
  [.[].type] == ["user","user"] and .[1].content[0].text == "next"
' >/dev/null

# Unknown records are rejected.
if print -r -- '[{"type":"mystery"}]' | fold >/dev/null 2>&1; then
  fail 'unrecognized session record was accepted'
fi
