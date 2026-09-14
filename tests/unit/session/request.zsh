#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

# envelope HOOK SCRIPT BODY [SCRIPT BODY ...]
envelope() {
  local hook=$1 entries=''
  shift
  while (( $# )); do
    entries+="<context script=\"$1\">$2</context>"$'\n'
    shift 2
  done
  print -rn -- "<hook name=\"$hook\">"$'\n'"$entries</hook>"
}

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
  {"type":"hook_result","hook":"user_prompt_submit","script":"user_shell","model_context":"a"},
  {"type":"state","name":"between/context","value":null},
  {"type":"hook_result"},
  {"type":"hook_result","hook":"user_prompt_submit","script":"user_shell","model_context":"b"},
  {"type":"state","name":"before/user","value":{"nested":true}},
  {"type":"user","content":[{"type":"text","text":"second"}]},
  {"type":"state","name":"trailing","value":false}
]' | fold | jq -e --arg ctx "$(envelope user_prompt_submit user_shell a user_shell b)" '
  length == 2 and .[0].content[0].text == "first" and
  .[1].content[0].text == $ctx + "\n\nsecond"
' >/dev/null

# Model context prefixes the next user message.
print -r -- '[
  {"type":"hook_result","hook":"user_prompt_submit","script":"user_shell","model_context":"ctx"},
  {"type":"user","content":[{"type":"text","text":"hi"}]}
]' | fold | jq -e --arg ctx "$(envelope user_prompt_submit user_shell ctx)" '
  (. | length) == 1 and .[0].type == "user" and
  .[0].content[0].text == $ctx + "\n\nhi"
' >/dev/null

# Adjacent contexts from one hook share a group and retain order.
print -r -- '[
  {"type":"hook_result","hook":"user_prompt_submit","script":"user_shell","model_context":"one"},
  {"type":"hook_result","hook":"user_prompt_submit","script":"user_shell","model_context":"two"},
  {"type":"hook_result","hook":"user_prompt_submit","script":"user_shell","model_context":"three"},
  {"type":"user","content":[{"type":"text","text":"hi"}]}
]' | fold | jq -e --arg ctx \
  "$(envelope user_prompt_submit user_shell one user_shell two user_shell three)" '
  (. | length) == 1 and .[0].content[0].text == $ctx + "\n\nhi"
' >/dev/null

# Markup in a body reaches the model verbatim.
print -r -- '[
  {"type":"hook_result","hook":"stop","script":"summary",
   "model_context":"<note>a && b</note>"},
  {"type":"user","content":[{"type":"text","text":"hi"}]}
]' | fold | jq -e '
  .[0].content[0].text ==
    "<hook name=\"stop\">\n<context script=\"summary\">" +
    "<note>a && b</note></context>\n</hook>\n\nhi"
' >/dev/null

# Pending context cannot split a tool pair.
print -r -- '[
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"hook_result","hook":"user_prompt_submit","script":"user_shell","model_context":"ctx"},
  {"type":"tool_result","call_id":"c1","name":"shell",
   "input":{},"stdout":"out","stderr":"err","exit_code":0},
  {"type":"user","content":[{"type":"text","text":"next"}]}
]' | fold | jq -e --arg ctx "$(envelope user_prompt_submit user_shell ctx)" '
  [.[].type] == ["assistant","tool_call","tool_result","user"] and
  .[1] == {type:"tool_call",id:"c1",name:"shell",input:{}} and
  (.[2] | has("input", "stdout", "stderr") | not) and
  .[2].content == "outerr" and
  .[3].content[0].text == $ctx + "\n\nnext"
' >/dev/null

# Correlated context surrounds its own tool result in lifecycle order.
print -r -- '[
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"hook_result","hook":"pre_tool_use","script":"guard","tool_use_id":"c1","model_context":"pre"},
  {"type":"hook_result","hook":"permission_request","script":"review",
   "tool_use_id":"c1","model_context":"permission"},
  {"type":"tool_result","call_id":"c1","name":"shell",
   "input":{},"stdout":"out","stderr":"","exit_code":0},
  {"type":"hook_result","hook":"post_tool_use","script":"format","tool_use_id":"c1",
   "model_context":"post"},
  {"type":"user","content":[{"type":"text","text":"next"}]}
]' | fold | jq -e \
  --arg pre "$(envelope pre_tool_use guard pre)" \
  --arg permission "$(envelope permission_request review permission)" \
  --arg post "$(envelope post_tool_use format post)" '
  [.[].type] == ["assistant","tool_call","tool_result","user"] and
  .[2].content == $pre + "\n\n" + $permission + "\n\nout\n\n" + $post and
  .[3].content[0].text == "next"
' >/dev/null

# A reused call ID correlates within its own response.
print -r -- '[
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"tool_result","call_id":"c1","name":"shell",
   "input":{},"stdout":"first","stderr":"","exit_code":0},
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"hook_result","hook":"pre_tool_use","script":"guard","tool_use_id":"c1","model_context":"second pre"},
  {"type":"tool_result","call_id":"c1","name":"shell",
   "input":{},"stdout":"second","stderr":"","exit_code":0}
]' | fold | jq -e --arg ctx "$(envelope pre_tool_use guard "second pre")" '
  [.[] | select(.type == "tool_result") | .content] == ["first", $ctx + "\n\nsecond"]
' >/dev/null

# Correlated context without a settled result is dropped.
print -r -- '[
  {"type":"assistant","stop":"tool_calls","content":[]},
  {"type":"hook_result","hook":"pre_tool_use","script":"guard","tool_use_id":"c1","model_context":"orphan"},
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
