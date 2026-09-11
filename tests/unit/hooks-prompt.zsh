#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"

make_script nul_argv 'print -rn -u3 -- '\''{"action":"handoff","argv":["bad\u0000arg"]}'\''; exit 11'
typeset nul_argv=$script
make_script empty_command 'print -rn -u3 -- '\''{"action":"handoff","argv":[""]}'\''; exit 11'
typeset empty_command=$script
make_script session_update 'print -rn -u3 -- '\''{"action":"session_update","patch":{"harness":{"sandbox_write_paths":["/tmp/reference"]}}}'\''; exit 11'
typeset session_update=$script
make_script invalid_update 'print -rn -u3 -- '\''{"action":"session_update","patch":[]}'\''; exit 11'
typeset invalid_update=$script
make_script metadata_only 'print -rn -u3 -- '\''{"context":{"prompt":"false","status":1}}'\''; exit 10'
typeset metadata_only=$script

# The user_prompt_submit hook preserves exact prompt bytes.
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
      user_prompt_submit:[{command:$script,display:"",environment:[]}]}
  }
')
sf_test_session "$prompt_session"
sf_hooks_turn_state_create
run_prompt_hook $'first\nsecond\n' "$prompt_session"
[[ ${#reply} == 1 && $reply[1] == proceed ]]
typeset accepted_turn=$SHELLFISH_TURN_ID
[[ $accepted_turn == 1 && ${(t)SHELLFISH_TURN_ID} != *export* ]]
jq -eRs '
  [split("\n")[] | select(length > 0) | fromjson] as $records |
  $records[-1] == {type:"hook_result",hook:"user_prompt_submit",script:"prompt",
    model_context:"first\nsecond\ncontext"}
' "$prompt_session" >/dev/null

# Prompt matching skips a component before invocation and continues in configured order.
typeset select_session="$tmp/select-session.jsonl" select_newline_session="$tmp/select-newline-session.jsonl"
typeset select_marker="$tmp/unmatched"
typeset select_events="$tmp/select-events"
make_script unmatched ': >"$SELECT_MARKER"'
typeset unmatched=$script saved_runtime=$SF_TEST_RUNTIME
SF_TEST_RUNTIME=$(jq -c --arg unmatched "$unmatched" --arg prompt "$prompt_script" '
  .harness.user_prompt_submit = [
    {command:$unmatched,display:"Must not display",environment:[],match:{pattern:"^!"}},
    {command:$prompt,display:"",environment:[],match:{pattern:"^ordinary$"}}
  ]
' <<<"$SF_TEST_RUNTIME")
sf_test_session "$select_session"
SF_HOOK_JSONL=1 SELECT_MARKER="$select_marker" \
  run_prompt_hook ordinary "$select_session" >"$select_events"
[[ ! -e $select_marker ]]
jq -e -s '
  . == [{type:"hook_result",hook:"user_prompt_submit",script:"prompt",
    model_context:"ordinarycontext"}]
' "$select_events" >/dev/null
jq -e 'select(.type == "hook_result" and .script == "prompt" and
  .model_context == "ordinarycontext")' < <(tail -n 1 "$select_session") >/dev/null
SF_TEST_RUNTIME=$(jq -c --arg unmatched "$unmatched" '
  .harness.user_prompt_submit = [
    {command:$unmatched,display:"Must not display",environment:[],
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
jq -e 'select(.type == "hook_result" and .model_context == "commandcontext" and
  .user_context == "blocked")' \
  < <(tail -n 1 "$prompt_session") >/dev/null
META=1 run_prompt_hook '!false' "$prompt_session"
jq -e '
  select(.type == "hook_result" and .script == "prompt" and
    .prompt == "false" and .status == 1 and .model_context == "!falsecontext")
' < <(tail -n 1 "$prompt_session") >/dev/null
BINARY=1 run_prompt_hook binary "$prompt_session"
[[ ${#reply} == 1 && $reply[1] == proceed ]]
jq -e 'select(.type == "hook_result" and .model_context == "binarycontext\u0000tail")' \
  < <(tail -n 1 "$prompt_session") >/dev/null
jq -e -s '.[-2] == {type:"state",name:"binary/context",value:true}' \
  "$prompt_session" >/dev/null
# Model context emitted with a handoff is already durable.
CONTROL="$tmp/switched.jsonl" run_prompt_hook /switch "$prompt_session"
[[ ${#reply} == 3 && $reply[1] == handoff && $reply[2] == /usr/bin/printf &&
   $reply[3] == "$tmp/switched.jsonl" ]]
jq -e 'select(.type == "hook_result" and .model_context == "/switchcontext")' \
  < <(tail -n 1 "$prompt_session") >/dev/null

# A session update is returned to exec for application during the turn.
SF_TEST_RUNTIME=$(jq -c --arg script "$session_update" '
  .harness.user_prompt_submit=[{command:$script,display:"",environment:[]}]
' <<<"$SF_TEST_RUNTIME")
typeset update_session="$tmp/update-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$update_session"
sf_hooks_turn_state_create
run_prompt_hook /update "$update_session"
[[ ${#reply} == 2 && $reply[1] == session_update ]]
jq -e '. == {harness:{sandbox_write_paths:["/tmp/reference"]}}' <<<"$reply[2]" >/dev/null

SF_TEST_RUNTIME=$(jq -c --arg script "$invalid_update" '
  .harness.user_prompt_submit=[{command:$script,display:"",environment:[]}]
' <<<"$SF_TEST_RUNTIME")
typeset invalid_update_session="$tmp/invalid-update-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$invalid_update_session"
sf_hooks_turn_state_create
if run_prompt_hook /update "$invalid_update_session"; then
  fail 'non-object session update was accepted'
fi
[[ $SF_HOOK_ERROR == 'user_prompt_submit hook script returned invalid control data' ]]

# Prompt and status metadata require model context in the same result.
SF_TEST_RUNTIME=$(jq -c --arg script "$metadata_only" '
  .harness.user_prompt_submit=[{command:$script,display:"",environment:[]}]
' <<<"$SF_TEST_RUNTIME")
typeset metadata_session="$tmp/metadata-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$metadata_session"
sf_hooks_turn_state_create
if run_prompt_hook /metadata "$metadata_session"; then
  fail 'context metadata without model context was accepted'
fi
[[ $SF_HOOK_ERROR == 'user_prompt_submit hook script returned invalid control data' ]]

# Exit 11 may halt the remaining prompt scripts without requesting a handoff.
make_script halt 'print -rn -- halted; exit 11'
typeset halt=$script
SF_TEST_RUNTIME=$(jq -c --arg script "$halt" '
  .harness.user_prompt_submit=[{command:$script,display:"",environment:[]}]
' <<<"$SF_TEST_RUNTIME")
typeset halt_session="$tmp/halt-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$halt_session"
sf_hooks_turn_state_create
run_prompt_hook /halt "$halt_session"
[[ ${#reply} == 1 && $reply[1] == handled ]]
jq -e 'select(.type == "hook_result" and .model_context == "halted")' \
  < <(tail -n 1 "$halt_session") >/dev/null

SF_TEST_RUNTIME=$(jq -c --arg script "$nul_argv" '
  .harness.user_prompt_submit=[{command:$script,display:"",environment:[]}]
' <<<"$SF_TEST_RUNTIME")
typeset nul_session="$tmp/nul-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$nul_session"
sf_hooks_turn_state_create
if run_prompt_hook /switch "$nul_session"; then
  fail 'NUL-containing handoff argument was accepted'
fi
[[ $SF_HOOK_ERROR == 'user_prompt_submit hook script returned invalid control data' ]]
SF_TEST_RUNTIME=$(jq -c --arg script "$empty_command" '
  .harness.user_prompt_submit=[{command:$script,display:"",environment:[]}]
' <<<"$SF_TEST_RUNTIME")
typeset empty_command_session="$tmp/empty-command-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$empty_command_session"
sf_hooks_turn_state_create
if run_prompt_hook /switch "$empty_command_session"; then
  fail 'empty handoff executable was accepted'
fi
[[ $SF_HOOK_ERROR == 'user_prompt_submit hook script returned invalid control data' ]]

make_script invalid_earlier 'print -n earlier; print -rn -u3 -- '\''{"unknown":true}'\''; exit 0'
typeset invalid_earlier=$script
SF_TEST_RUNTIME=$(jq -c --arg first "$invalid_earlier" --arg second "$prompt_script" '
  .harness.user_prompt_submit=([$first,$second] | map({command:.,display:"",environment:[]}))
' <<<"$SF_TEST_RUNTIME")
typeset invalid_control_session="$tmp/invalid-control-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$invalid_control_session"
sf_hooks_turn_state_create
if run_prompt_hook ordinary "$invalid_control_session"; then
  fail 'invalid earlier prompt control was accepted'
fi
[[ $SF_HOOK_ERROR == 'user_prompt_submit hook script returned invalid control data' ]]

sf_hooks_turn_state_cleanup
assert_no_hook_captures
