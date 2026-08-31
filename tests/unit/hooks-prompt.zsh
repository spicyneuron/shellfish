#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"

make_hook nul_argv 'print -rn -u3 -- '\''{"action":"handoff","argv":["bad\u0000arg"]}'\''; exit 11'
typeset nul_argv=$hook
make_hook empty_command 'print -rn -u3 -- '\''{"action":"handoff","argv":[""]}'\''; exit 11'
typeset empty_command=$hook

# The prompt hook runs under the session lock and preserves exact prompt bytes.
typeset prompt_session="$tmp/prompt-session.jsonl"
typeset prompt_hook
make_hook prompt '[[ $1 == user_prompt_submit && $SHELLFISH_TURN_ID == 1 ]]; [[ $SHELLFISH_SESSION == /* && $SHELLFISH_SESSION_ID == prompt-session && $SHELLFISH_MODEL == test ]]; [[ $PROJECT_DIR == $PWD && $PLUGIN_ROOT == ${0:A:h} && -d $SHELLFISH_TURN_STATE && -d $SHELLFISH_SESSION_STATE ]]; cat; print -n context; [[ -z $CONTROL ]] || { jq -cn --arg path "$CONTROL" '\''{action:"handoff",argv:["/usr/bin/printf",$path]}'\'' >&3; exit 11 }; [[ -z $META ]] || { print -rn -u3 -- '\''{"context":{"prompt":"false","status":1}}'\''; exit 10 }; [[ -z $BINARY ]] || print -rn -- $'\''\0tail'\''; [[ -z $SKIP ]] || { print -rn -u2 -- blocked; exit 10; }'
prompt_hook=$hook
typeset -g SF_TEST_RUNTIME=$(jq -cn --arg hook "$prompt_hook" '
  {
    profile:{request:{model:"test"}},
    backend:{name:"test",command:"/usr/bin/false",endpoint:"https://example.invalid",
      api_key_env:"",env_file:"",insecure_tls:false,http_timeout:1,http_stall:1},
    harness:{sandbox_read_paths:[],sandbox_write_paths:[],fence:"",tools:[],sandbox:false,max_requests_per_turn:1,
      max_tool_calls_per_request:1,max_capture_bytes:512,user_prompt_submit:[$hook]}
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
  $records[-1] == {type:"context",tag:"user_prompt_submit",hook:"prompt",
    content:"first\nsecond\ncontext"}
' "$prompt_session" >/dev/null
SKIP=1 run_prompt_hook command "$prompt_session"
[[ ${#reply} == 1 && $reply[1] == handled ]]
[[ -z ${SHELLFISH_TURN_ID-} ]]
[[ $SF_HOOK_RESULTS[4] == blocked ]]
jq -e 'select(.type == "context" and .content == "commandcontext")' \
  < <(tail -n 1 "$prompt_session") >/dev/null
META=1 run_prompt_hook '!false' "$prompt_session"
jq -e '
  select(.type == "context" and .hook == "prompt" and
    .prompt == "false" and .status == 1 and .content == "!falsecontext")
' < <(tail -n 1 "$prompt_session") >/dev/null
BINARY=1 run_prompt_hook binary "$prompt_session"
[[ ${#reply} == 1 && $reply[1] == proceed ]]
jq -e 'select(.type == "context" and .content == "binarycontext\u0000tail")' \
  < <(tail -n 1 "$prompt_session") >/dev/null
# Prompt hooks may request a handoff; the locked path still commits its context.
CONTROL="$tmp/switched.jsonl" run_prompt_hook /switch "$prompt_session"
[[ ${#reply} == 3 && $reply[1] == handoff && $reply[2] == /usr/bin/printf &&
   $reply[3] == "$tmp/switched.jsonl" ]]
jq -e 'select(.type == "context" and .content == "/switchcontext")' \
  < <(tail -n 1 "$prompt_session") >/dev/null
SF_TEST_RUNTIME=$(jq -c --arg hook "$nul_argv" '
  .harness.user_prompt_submit=[$hook]
' <<<"$SF_TEST_RUNTIME")
typeset nul_session="$tmp/nul-session.jsonl"
sf_test_session "$nul_session"
if run_prompt_hook /switch "$nul_session"; then
  fail 'NUL-containing handoff argument was accepted'
fi
[[ $SF_HOOK_ERROR == 'prompt hook returned invalid control data' ]]
SF_TEST_RUNTIME=$(jq -c --arg hook "$empty_command" '
  .harness.user_prompt_submit=[$hook]
' <<<"$SF_TEST_RUNTIME")
typeset empty_command_session="$tmp/empty-command-session.jsonl"
sf_test_session "$empty_command_session"
if run_prompt_hook /switch "$empty_command_session"; then
  fail 'empty handoff executable was accepted'
fi
[[ $SF_HOOK_ERROR == 'prompt hook returned invalid control data' ]]

make_hook invalid_earlier 'print -n earlier; print -rn -u3 -- '\''{"unknown":true}'\''; exit 0'
typeset invalid_earlier=$hook
SF_TEST_RUNTIME=$(jq -c --arg first "$invalid_earlier" --arg second "$prompt_hook" '
  .harness.user_prompt_submit=[$first,$second]
' <<<"$SF_TEST_RUNTIME")
typeset invalid_control_session="$tmp/invalid-control-session.jsonl"
sf_test_session "$invalid_control_session"
if run_prompt_hook ordinary "$invalid_control_session"; then
  fail 'invalid earlier prompt control was accepted'
fi
[[ $SF_HOOK_ERROR == 'prompt hook returned invalid control data' ]]

sf_hooks_turn_state_cleanup
assert_no_hook_captures
