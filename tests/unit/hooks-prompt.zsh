#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"

make_script session_update 'print -rn -u3 -- '\''{"action":"session_update","patch":{"harness":{"sandbox_write_paths":["/tmp/reference"]}}}'\''; exit 11'
typeset session_update=$script
make_script invalid_update 'print -rn -u3 -- '\''{"action":"session_update","patch":[]}'\''; exit 11'
typeset invalid_update=$script

# Preserve exact prompt bytes.
typeset prompt_session="$tmp/prompt-session.jsonl"
typeset prompt_script
make_script prompt '[[ $1 == user_prompt_submit && $SHELLFISH_TURN_ID == 1 ]]; [[ $SHELLFISH_SESSION == /* && $SHELLFISH_MODEL == test ]]; [[ $0 == /* && -d ${0:A:h} && -d $SHELLFISH_TURN_STATE ]]; cat; print -n context; [[ -z $CONTROL ]] || { jq -cn --arg path "$CONTROL" '\''{action:"handoff",argv:["/usr/bin/printf",$path]}'\'' >&3; exit 11 }; [[ -z $META ]] || { print -rn -u3 -- '\''{"context":{"prompt":"false","status":1}}'\''; exit 10 }; [[ -z $BINARY ]] || { print -rn -- $'\''\0tail'\''; print -rn -u3 -- '\''{"state":[{"name":"binary/context","value":true}]}'\''; }; [[ -z $SKIP ]] || { print -rn -u2 -- blocked; exit 10; }'
prompt_script=$script
typeset -g SF_TEST_RUNTIME=$(jq -cn --arg script "$prompt_script" '
  {
    profile:{request:{model:"test"}},
    backend:{name:"test",command:"/usr/bin/false",endpoint:"https://example.invalid",
      environment:[],env_file:"",insecure_tls:false,http_timeout:1,http_stall:1},
    harness:{sandbox_read_paths:[],sandbox_write_paths:[],fence:"",tools:[],sandbox:false,max_requests_per_turn:1,
      max_tool_calls_per_request:1,max_capture_bytes:512,
      user_prompt_submit:[{command:$script,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}]}
  }
')
sf_test_session "$prompt_session"
sf_hooks_turn_state_create
run_prompt_hook $'first\nsecond\n' "$prompt_session"
[[ ${#reply} == 1 && $reply[1] == proceed ]]
typeset accepted_turn=$SHELLFISH_TURN_ID
[[ $accepted_turn == 1 && ${(t)SHELLFISH_TURN_ID} != *export* ]]
jq -eRs --arg executable "$prompt_script" '
  [split("\n")[] | select(length > 0) | fromjson] as $records |
  $records[-1] as $result |
  ($result | del(.id)) == {type:"hook_result",lifecycle:"user_prompt_submit",name:"prompt",
    input:"first\nsecond\n",executable:$executable,exit_code:0,
    model_text:"<hook name=\"user_prompt_submit\">\n<context script=\"prompt\">first\nsecond\ncontext</context>\n</hook>"} and
  ($result.id | test("^[1-9][0-9]*$"))
' "$prompt_session" >/dev/null

# Prompt matching occurs before invocation.
typeset select_session="$tmp/select-session.jsonl" select_newline_session="$tmp/select-newline-session.jsonl"
typeset select_marker="$tmp/unmatched"
typeset select_events="$tmp/select-events"
make_script unmatched ': >"$SELECT_MARKER"'
typeset unmatched=$script saved_runtime=$SF_TEST_RUNTIME
SF_TEST_RUNTIME=$(jq -c --arg unmatched "$unmatched" --arg prompt "$prompt_script" '
  .harness.user_prompt_submit = [
    {command:$unmatched,environment:[],render:{user_before:"Must not display",user_after:"",model_after:"${output.stdout}"},match:{pattern:"^!"}},
    {command:$prompt,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"},match:{pattern:"^ordinary$"}}
  ]
' <<<"$SF_TEST_RUNTIME")
sf_test_session "$select_session"
SF_HOOK_JSONL=1 SELECT_MARKER="$select_marker" \
  run_prompt_hook ordinary "$select_session" >"$select_events"
[[ ! -e $select_marker ]]
jq -e -s --arg executable "$prompt_script" '
  length == 2 and .[0].id == .[1].id and
  (.[0] | del(.id)) == {type:"_hook_activity",hook:"user_prompt_submit",name:"prompt",
    input:"ordinary",executable:$executable} and
  (.[1] | del(.id,.model_text)) == {type:"hook_result",lifecycle:"user_prompt_submit",
    name:"prompt",input:"ordinary",executable:$executable,exit_code:0} and
  .[1].model_text == "<hook name=\"user_prompt_submit\">\n<context script=\"prompt\">ordinarycontext</context>\n</hook>"
' "$select_events" >/dev/null
jq -e --arg executable "$prompt_script" 'select(.type == "hook_result" and
  .executable == $executable and (.model_text | contains("ordinarycontext")))' \
  < <(tail -n 1 "$select_session") >/dev/null
SF_TEST_RUNTIME=$(jq -c --arg unmatched "$unmatched" '
  .harness.user_prompt_submit = [
    {command:$unmatched,environment:[],render:{user_before:"Must not display",user_after:"",model_after:"${output.stdout}"},
      match:{pattern:"^ordinary\\z"}}
  ]
' <<<"$SF_TEST_RUNTIME")
sf_test_session "$select_newline_session"
SF_HOOK_JSONL=1 SELECT_MARKER="$select_marker" \
  run_prompt_hook $'ordinary\n' "$select_newline_session" >"$select_events"
[[ ! -e $select_marker ]]
[[ ! -s $select_events ]]
SF_TEST_RUNTIME=$saved_runtime

SKIP=1 run_prompt_hook command "$prompt_session"
[[ ${#reply} == 1 && $reply[1] == handled ]]
[[ -z ${SHELLFISH_TURN_ID-} ]]
jq -e 'select(.type == "hook_result" and (.model_text | contains("commandcontext")) and
  (has("user_text") | not) and .exit_code == 10)' \
  < <(tail -n 1 "$prompt_session") >/dev/null
if META=1 run_prompt_hook '!false' "$prompt_session"; then
  fail 'removed hook presentation control was accepted'
fi
[[ $SF_HOOK_ERROR == 'user_prompt_submit hook script returned invalid control data' ]]
BINARY=1 run_prompt_hook binary "$prompt_session"
[[ ${#reply} == 1 && $reply[1] == proceed ]]
jq -e 'select(.type == "hook_result" and (.model_text | contains("binarycontext\u0000tail")))' \
  < <(tail -n 1 "$prompt_session") >/dev/null
jq -e -s '.[-2] == {type:"state",name:"binary/context",value:true}' \
  "$prompt_session" >/dev/null
# Handoff model context is already durable.
CONTROL="$tmp/switched.jsonl" run_prompt_hook /switch "$prompt_session"
[[ ${#reply} == 3 && $reply[1] == handoff && $reply[2] == /usr/bin/printf &&
   $reply[3] == "$tmp/switched.jsonl" ]]
jq -e 'select(.type == "hook_result" and (.model_text | contains("/switchcontext")))' \
  < <(tail -n 1 "$prompt_session") >/dev/null

# Return session updates to exec.
SF_TEST_RUNTIME=$(jq -c --arg script "$session_update" '
  .harness.user_prompt_submit=[{command:$script,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
typeset update_session="$tmp/update-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$update_session"
sf_hooks_turn_state_create
run_prompt_hook /update "$update_session"
[[ ${#reply} == 2 && $reply[1] == session_update ]]
jq -e '. == {harness:{sandbox_write_paths:["/tmp/reference"]}}' <<<"$reply[2]" >/dev/null

SF_TEST_RUNTIME=$(jq -c --arg script "$invalid_update" '
  .harness.user_prompt_submit=[{command:$script,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
typeset invalid_update_session="$tmp/invalid-update-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$invalid_update_session"
sf_hooks_turn_state_create
if run_prompt_hook /update "$invalid_update_session"; then
  fail 'non-object session update was accepted'
fi
[[ $SF_HOOK_ERROR == 'user_prompt_submit hook script returned invalid control data' ]]

# Halt remaining prompt hooks.
make_script halt 'print -rn -- halted; exit 11'
typeset halt=$script
SF_TEST_RUNTIME=$(jq -c --arg script "$halt" '
  .harness.user_prompt_submit=[{command:$script,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
typeset halt_session="$tmp/halt-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$halt_session"
sf_hooks_turn_state_create
run_prompt_hook /halt "$halt_session"
[[ ${#reply} == 1 && $reply[1] == handled ]]
jq -e 'select(.type == "hook_result" and (.model_text | contains("halted")))' \
  < <(tail -n 1 "$halt_session") >/dev/null

sf_hooks_turn_state_cleanup
assert_no_hook_captures
