#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"

make_script nul_argv 'print -rn -u3 -- '\''{"action":"handoff","argv":["bad\u0000arg"]}'\''; exit 11'
typeset nul_argv=$script
make_script empty_command 'print -rn -u3 -- '\''{"action":"handoff","argv":[""]}'\''; exit 11'
typeset empty_command=$script

# The user_prompt_submit hook runs under the session lock and preserves exact prompt bytes.
typeset prompt_session="$tmp/prompt-session.jsonl"
typeset prompt_script
make_script prompt '[[ $1 == user_prompt_submit && $SHELLFISH_TURN_ID == 1 ]]; [[ $SHELLFISH_SESSION == /* && $SHELLFISH_SESSION_ID == prompt-session && $SHELLFISH_MODEL == test ]]; [[ $PROJECT_DIR == $PWD && $HOOK_SCRIPT_ROOT == ${0:A:h} && -d $SHELLFISH_TURN_STATE && -d $SHELLFISH_SESSION_STATE ]]; cat; print -n context; [[ -z $CONTROL ]] || { jq -cn --arg path "$CONTROL" '\''{action:"handoff",argv:["/usr/bin/printf",$path]}'\'' >&3; exit 11 }; [[ -z $META ]] || { print -rn -u3 -- '\''{"context":{"prompt":"false","status":1}}'\''; exit 10 }; [[ -z $BINARY ]] || print -rn -- $'\''\0tail'\''; [[ -z $SKIP ]] || { print -rn -u2 -- blocked; exit 10; }'
prompt_script=$script
typeset -g SF_TEST_RUNTIME=$(jq -cn --arg script "$prompt_script" '
  {
    profile:{request:{model:"test"}},
    backend:{name:"test",command:"/usr/bin/false",endpoint:"https://example.invalid",
      api_key_env:"",env_file:"",insecure_tls:false,http_timeout:1,http_stall:1},
    harness:{system:[],sandbox_read_paths:[],sandbox_write_paths:[],fence:"",tools:[],sandbox:false,max_requests_per_turn:1,
      max_tool_calls_per_request:1,max_capture_bytes:512,user_prompt_submit:[$script]}
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
  $records[-1] == {type:"context",hook:"user_prompt_submit",script:"prompt",
    content:"first\nsecond\ncontext"}
' "$prompt_session" >/dev/null
SKIP=1 run_prompt_hook command "$prompt_session"
[[ ${#reply} == 1 && $reply[1] == handled ]]
[[ -z ${SHELLFISH_TURN_ID-} ]]
[[ $SF_HOOK_SCRIPT_RESULTS[4] == blocked ]]
jq -e 'select(.type == "context" and .content == "commandcontext")' \
  < <(tail -n 1 "$prompt_session") >/dev/null
META=1 run_prompt_hook '!false' "$prompt_session"
jq -e '
  select(.type == "context" and .script == "prompt" and
    .prompt == "false" and .status == 1 and .content == "!falsecontext")
' < <(tail -n 1 "$prompt_session") >/dev/null
BINARY=1 run_prompt_hook binary "$prompt_session"
[[ ${#reply} == 1 && $reply[1] == proceed ]]
jq -e 'select(.type == "context" and .content == "binarycontext\u0000tail")' \
  < <(tail -n 1 "$prompt_session") >/dev/null
# user_prompt_submit scripts may request a handoff; the locked path still commits their context.
CONTROL="$tmp/switched.jsonl" run_prompt_hook /switch "$prompt_session"
[[ ${#reply} == 3 && $reply[1] == handoff && $reply[2] == /usr/bin/printf &&
   $reply[3] == "$tmp/switched.jsonl" ]]
jq -e 'select(.type == "context" and .content == "/switchcontext")' \
  < <(tail -n 1 "$prompt_session") >/dev/null

# Exit 11 may halt the remaining prompt scripts without requesting a handoff.
make_script halt 'print -rn -- halted; exit 11'
typeset halt=$script
SF_TEST_RUNTIME=$(jq -c --arg script "$halt" '
  .harness.user_prompt_submit=[$script]
' <<<"$SF_TEST_RUNTIME")
typeset halt_session="$tmp/halt-session.jsonl"
sf_hooks_turn_state_cleanup
sf_test_session "$halt_session"
sf_hooks_turn_state_create
run_prompt_hook /halt "$halt_session"
[[ ${#reply} == 1 && $reply[1] == handled ]]
jq -e 'select(.type == "context" and .content == "halted")' \
  < <(tail -n 1 "$halt_session") >/dev/null

SF_TEST_RUNTIME=$(jq -c --arg script "$nul_argv" '
  .harness.user_prompt_submit=[$script]
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
  .harness.user_prompt_submit=[$script]
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
  .harness.user_prompt_submit=[$first,$second]
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
