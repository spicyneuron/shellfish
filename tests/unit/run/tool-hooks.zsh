#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh

typeset stream
sf_test_tmp exec-tool-hooks
export XDG_STATE_HOME="$tmp/state"
export TEST_OUTPUT_DIR="$tmp/hook-output"
mkdir "$TEST_OUTPUT_DIR"
typeset system_file="$tmp/system.md"
typeset request_capture="$tmp/request.json"
printf 'frozen system\n' >"$system_file"

sf_test_runtime "$system_file"
export SF_TEST_BACKEND_DELAY=0
export SF_TEST_BACKEND_REQUEST="$request_capture"

# Tool observers receive canonical envelopes.
typeset pre_observe="$tmp/pre-observe"
cat >"$pre_observe" <<'ZSH'
#!/usr/bin/env zsh
set -e
[[ $# == 1 && $1 == pre_tool_use ]]
input=$(cat)
call_id=$(jq -r '.tool.id' <<<"$input")
print -rn -- "$input" >"$TEST_OUTPUT_DIR/pre-$call_id"
jq -cn --arg id "$call_id" '{state:[{name:"tools/pre",value:$id}]}' >&3
print -rn -u2 -- "pre-local-$call_id"
print -rn -- "pre context $call_id"
ZSH
chmod +x "$pre_observe"
typeset post_observe="$tmp/post-observe"
cat >"$post_observe" <<'ZSH'
#!/usr/bin/env zsh
set -e
[[ $# == 1 && $1 == post_tool_use ]]
[[ $SHELLFISH_TURN_ID == 1 && $SHELLFISH_MODEL == test-model &&
  $0 == /* && -d ${0:A:h} ]]
input=$(cat)
call_id=$(jq -r '.tool.id' <<<"$input")
print -rn -- "$input" >"$TEST_OUTPUT_DIR/post-$call_id"
jq -cn --arg id "$call_id" '{state:[{name:"tools/post",value:$id}]}' >&3
print -rn -u2 -- "post-local-$call_id"
print -rn -- "post context $call_id"
ZSH
chmod +x "$post_observe"
SF_TEST_RUNTIME=$(jq -c --arg pre "$pre_observe" --arg post "$post_observe" '
  .harness.pre_tool_use=[{command:$pre,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}] |
  .harness.post_tool_use=[{command:$post,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}] |
  .harness.sandbox=false
' <<<"$SF_TEST_RUNTIME")
typeset observe_session="$tmp/tool-observe.jsonl"
sf_test_session "$observe_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=2 \
  SF_TEST_BACKEND_TOOL_COMMAND="printf 'line\\n\\n'; exit 7" \
  sf_test_turn observe "$observe_session")
# Lifecycle hooks settle nothing of their own; their model text folds into the
# owning call, and every state record still lands in lifecycle order.
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "hook_result"))) == [] and
  ($events | map(select(.type == "state" or .type == "tool_result")) |
    map(if .type == "state" then [.name,.value] else ["result",.id] end)) ==
    [["tools/pre","call_1"],["tools/post","call_1"],["result","call_1"],
     ["tools/pre","call_2"],["tools/post","call_2"],["result","call_2"]] and
  ($events | map(select(.type == "tool_result") | [.exit_code, .model_text])) ==
    [[7,"<hook name=\"pre_tool_use\">\n<context script=\"pre-observe\">pre context call_1</context>\n</hook>\n\nline\n\n\nexit 7\n\n<hook name=\"post_tool_use\">\n<context script=\"post-observe\">post context call_1</context>\n</hook>"],
     [7,"<hook name=\"pre_tool_use\">\n<context script=\"pre-observe\">pre context call_2</context>\n</hook>\n\nline\n\n\nexit 7\n\n<hook name=\"post_tool_use\">\n<context script=\"post-observe\">post context call_2</context>\n</hook>"]]
' >/dev/null
assert_canonical_session "$observe_session"
jq -e '. == {turn_id:1,tool:{id:"call_1",name:"shell",
  input:{command:"printf '\''line\\n\\n'\''; exit 7"}}}' \
  "$TEST_OUTPUT_DIR/pre-call_1" >/dev/null
jq -e '. == {turn_id:1,tool:{id:"call_1",name:"shell",
  input:{command:"printf '\''line\\n\\n'\''; exit 7"},
  output:{stdout:"line\n\n",stderr:"",exit_code:7}}}' \
  "$TEST_OUTPUT_DIR/post-call_1" >/dev/null
# The settled result carries that folded context straight into the request.
jq -e '
  ([.messages[-4:][].type]) == ["tool_call","tool_result","tool_call","tool_result"] and
  .messages[-3].content ==
    "<hook name=\"pre_tool_use\">\n" +
    "<context script=\"pre-observe\">pre context call_1</context>\n</hook>\n\n" +
    "line\n\n\nexit 7\n\n" +
    "<hook name=\"post_tool_use\">\n" +
    "<context script=\"post-observe\">post context call_1</context>\n</hook>"
' "$request_capture" >/dev/null

# Pre-hook denials preserve sibling calls.
typeset pre_deny="$tmp/pre-deny"
cat >"$pre_deny" <<'ZSH'
#!/usr/bin/env zsh
call_id=$(jq -r '.tool.id')
print -r -- "$call_id" >>"$TEST_OUTPUT_DIR/pre-calls"
[[ $SHELLFISH_TURN_ID == 1 && $SHELLFISH_MODEL == test-model &&
  $0 == /* && -d ${0:A:h} ]] || exit 1
[[ $call_id != call_2 ]] || { print -rn -- 'first reason'; exit 10 }
ZSH
chmod +x "$pre_deny"
typeset pre_later="$tmp/pre-later"
cat >"$pre_later" <<'ZSH'
#!/usr/bin/env zsh
call_id=$(jq -r '.tool.id')
print -r -- "$call_id" >>"$TEST_OUTPUT_DIR/pre-later-calls"
[[ $call_id != call_2 ]] || { print -rn -- 'second reason'; exit 11 }
ZSH
chmod +x "$pre_later"
typeset pre_never="$tmp/pre-never"
cat >"$pre_never" <<'ZSH'
#!/usr/bin/env zsh
jq -r '.tool.id' >>"$TEST_OUTPUT_DIR/pre-never-calls"
ZSH
chmod +x "$pre_never"
typeset post_log="$tmp/post-log"
cat >"$post_log" <<'ZSH'
#!/usr/bin/env zsh
jq -r '[.tool.id,(.tool.output.exit_code | tostring)] | join("|")' \
  >>"$TEST_OUTPUT_DIR/post-calls"
ZSH
chmod +x "$post_log"
SF_TEST_RUNTIME=$(jq -c --arg pre "$pre_deny" --arg later "$pre_later" \
  --arg never "$pre_never" --arg post "$post_log" '
  .harness.pre_tool_use=([$pre,$later,$never] | map({command:.,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}})) |
  .harness.post_tool_use=[{command:$post,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
typeset deny_session="$tmp/tool-deny.jsonl"
sf_test_session "$deny_session"
stream=$(SF_TEST_BACKEND_TOOL_CALL=1 SF_TEST_BACKEND_TOOL_COUNT=3 \
  sf_test_turn deny "$deny_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "tool_result") | .exit_code)) == [0,126,0] and
  ($events | map(select(.type == "tool_result"))[1].model_text |
    endswith("tool call denied by pre_tool_use hook: pre-deny\nexit 126"))
' >/dev/null
# Denial steering reaches the model as hook context beside the denied result.
jq -e '
  [.messages[] | select(.type == "tool_result")][1].content ==
    "<hook name=\"pre_tool_use\">\n" +
    "<context script=\"pre-deny\">first reason</context>\n</hook>\n\n" +
    "<hook name=\"pre_tool_use\">\n" +
    "<context script=\"pre-later\">second reason</context>\n</hook>\n\n" +
    "tool call denied by pre_tool_use hook: pre-deny\nexit 126"
' "$request_capture" >/dev/null
[[ $(<$TEST_OUTPUT_DIR/pre-calls) == $'call_1\ncall_2\ncall_3' ]]
[[ $(<$TEST_OUTPUT_DIR/pre-later-calls) == $'call_1\ncall_2\ncall_3' ]]
[[ $(<$TEST_OUTPUT_DIR/pre-never-calls) == $'call_1\ncall_3' ]]
[[ $(<$TEST_OUTPUT_DIR/post-calls) == \
  $'call_1|0\ncall_2|126\ncall_3|0' ]]
