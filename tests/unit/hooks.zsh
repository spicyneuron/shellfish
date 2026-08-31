#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"

# session_start runs during lock-free session creation, receives its hook name, and
# commits one attributed context record after the complete chain succeeds.
typeset start_session="$tmp/start-session.jsonl"
make_script start '[[ $# == 1 && $1 == session_start ]]; [[ ! -s /dev/stdin && -z ${SHELLFISH_TURN_ID-} ]]; [[ -z ${OPENAI_API_KEY-} && -z ${CUSTOM_API_KEY-} ]]; [[ -n $SHELLFISH_SESSION_ID && $SHELLFISH_MODEL == test && $PROJECT_DIR == $PWD ]]; [[ $SHELLFISH_CONFIG_DIR == "$EXPECTED_CONFIG_DIR" ]]; print -n startup; print -n -u2 local; [[ -z $SKIP ]] || exit 10'
typeset start_script=$script
make_script start_second 'print -n second'
typeset start_second_script=$script
typeset -gx EXPECTED_CONFIG_DIR="$tmp/config"
SF_TEST_RUNTIME=$(jq -cn --arg script "$start_script" --arg second "$start_second_script" \
  --arg env_file "$EXPECTED_CONFIG_DIR/.env" '
  {
    profile:{request:{model:"test"}},
    backend:{name:"test",command:"/usr/bin/false",endpoint:"https://example.invalid",
      api_key_env:"CUSTOM_API_KEY",env_file:$env_file,insecure_tls:false,http_timeout:1,http_stall:1},
    harness:{sandbox_read_paths:[],sandbox_write_paths:[],fence:"",tools:[],sandbox:false,max_requests_per_turn:1,
      max_tool_calls_per_request:1,max_capture_bytes:512,session_start:[$script,$second]}
  }
')
export OPENAI_API_KEY=standard-secret CUSTOM_API_KEY=custom-secret
SF_SESSION_PATH=$start_session
sf_hooks_session_state_create
sf_session_prepare "$SF_TEST_RUNTIME"
[[ ! -e ${start_session}.lock ]]
sf_hooks_session_start "$start_session"
[[ -z $REPLY && ${#reply} == 0 && $SF_HOOK_SCRIPT_RESULTS[4] == local ]]
[[ $OPENAI_API_KEY == standard-secret && $CUSTOM_API_KEY == custom-secret ]]
unset OPENAI_API_KEY CUSTOM_API_KEY
[[ ! -e $start_session ]]
sf_session_create "${SF_HOOK_CONTEXT_RECORDS[@]}"
jq -e -s '
  length == 3 and
  .[1] == {type:"context",hook:"session_start",script:"start",content:"startup"} and
  .[2] == {type:"context",hook:"session_start",script:"start_second",content:"second"}
' "$start_session" >/dev/null

# CLI entry runs creation hooks once and does not rerun them for an existing session.
typeset resume_session="$tmp/resume-session.jsonl"
typeset resume_marker="$tmp/resume-marker" resume_config="$tmp/resume-shellfish.jsonc"
make_script resume 'print -r -- run >>"$RESUME_MARKER"'
typeset resume_script=$script
cat >"$resume_config" <<EOF
{
  "default_profile": "test",
  "backends": {"fixture": {"adapter": "$ROOT/tests/fixtures/backend"}},
  "harnesses": {
    "test": {
      "system": [], "tools": [], "sandbox": false,
      "session_start": ["$resume_script"], "user_prompt_submit": [],
      "permission_request": [], "pre_tool_use": [], "post_tool_use": [], "stop": [],
      "max_requests_per_turn": 1, "max_tool_calls_per_request": 1,
      "max_capture_bytes": 512
    }
  },
  "profiles": {
    "test": {"backend": "fixture", "harness": "test", "request": {"model": "test"}}
  }
}
EOF
RESUME_MARKER=$resume_marker SF_TEST_BACKEND_DELAY=0 zsh -f "$SF_ENTRY" exec \
  --config "$resume_config" --session "$resume_session" first >/dev/null ||
  fail 'new-session CLI entry failed'
RESUME_MARKER=$resume_marker SF_TEST_BACKEND_DELAY=0 zsh -f "$SF_ENTRY" exec \
  --session "$resume_session" second >/dev/null ||
  fail 'existing-session CLI entry failed'
(( $(wc -l <"$resume_marker") == 1 )) || fail 'session_start hook ran more than once'

# Hook projection preserves a session working directory containing a newline.
typeset newline_cwd="$tmp/"$'line\nbreak' previous_cwd=$PWD
mkdir "$newline_cwd"
cd "$newline_cwd"
newline_cwd=$(pwd -P)
typeset newline_session="$tmp/newline-session.jsonl"
SF_SESSION_PATH=$newline_session
sf_session_prepare "$SF_TEST_RUNTIME"
sf_hooks_session_start "$newline_session"
sf_session_create "${SF_HOOK_CONTEXT_RECORDS[@]}"
cd "$previous_cwd"
jq -e -s --arg cwd "$newline_cwd" '.[0].cwd == $cwd' "$newline_session" >/dev/null

typeset skipped_session="$tmp/skipped-session.jsonl"
SF_SESSION_PATH=$skipped_session
sf_session_prepare "$SF_TEST_RUNTIME"
if SKIP=1 sf_hooks_session_start "$skipped_session"; then
  fail 'session_start skip status was accepted'
fi
[[ $SF_HOOK_ERROR == 'session_start hook script returned unsupported skip status' ]]
[[ ! -e $skipped_session ]]

# Startup has no control vocabulary, including when a hook stops its chain.
typeset control_session="$tmp/control-session.jsonl"
make_script start_control 'print -rn -u3 -- $'\''again\0'\''; exit 11'
SF_TEST_RUNTIME=$(jq -c --arg script "$script" \
  '.harness.session_start = [$script]' <<<"$SF_TEST_RUNTIME")
SF_SESSION_PATH=$control_session
sf_session_prepare "$SF_TEST_RUNTIME"
if sf_hooks_session_start "$control_session"; then
  fail 'session_start control data was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script returned unexpected control data: $script" ]]
[[ ! -e $control_session ]]

# Permission hooks receive a canonical envelope and may allow, deny with a reason,
# deny by status alone, or defer. Their stdout is never committed.
typeset permission_session="$tmp/permission-session.jsonl"
typeset permission_script="$scripts/permission"
cat >"$permission_script" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 1 && $1 == permission_request ]] || exit 1
[[ $SHELLFISH_TURN_ID == 1 && $SHELLFISH_SESSION_ID == permission-session ]] || exit 1
[[ $SHELLFISH_MODEL == test && $PROJECT_DIR == "$PWD" ]] || exit 1
[[ -d $SHELLFISH_TURN_STATE && -d $SHELLFISH_SESSION_STATE &&
  $SHELLFISH_SESSION_STATE == */sessions/permission-session &&
  ${PLUGIN_ROOT:A} == "${0:A:h}" ]] || exit 1
jq -e '. == {turn_id:1,tool_name:"shell",tool_use_id:"call_7",
  tool_input:{command:"true"}}' >/dev/null || exit 1
print -rn -- ignored
print -rn -u2 -- local
decision=$(cat "$SHELLFISH_TURN_STATE/decision")
case $decision in
  allow) print -rn -u3 -- '{"action":"allow"}'; exit 11 ;;
  deny) print -rn -u3 -- '{"action":"deny","reason":"not authorized\n"}'; exit 11 ;;
  skip) exit 10 ;;
  halt) exit 11 ;;
  malformed) print -rn -u3 -- '{"action":"allow","extra":true}'; exit 11 ;;
esac
ZSH
chmod +x "$permission_script"
SF_TEST_RUNTIME=$(jq -c --arg script "$permission_script" '
  .harness.permission_request=[$script] | del(.harness.session_start)
' <<<"$SF_TEST_RUNTIME")
sf_test_session "$permission_session"
sf_session_open "$permission_session"
SHELLFISH_SESSION_STATE=''
sf_hooks_turn_state_create
typeset -gx SHELLFISH_TURN_ID=1
print allow >"$SHELLFISH_TURN_STATE/decision"
sf_hooks_permission_request "$permission_session" shell call_7 \
  '{"command":"true"}'
[[ $reply[1] == allow && -z $reply[2] && $SF_HOOK_SCRIPT_RESULTS[4] == local ]]
(( $(wc -l <"$permission_session") == 1 ))
print deny >"$SHELLFISH_TURN_STATE/decision"
sf_hooks_permission_request "$permission_session" shell call_7 \
  '{"command":"true"}'
[[ $reply[1] == deny && $reply[2] == $'not authorized\n' ]]
print skip >"$SHELLFISH_TURN_STATE/decision"
sf_hooks_permission_request "$permission_session" shell call_7 \
  '{"command":"true"}'
[[ $reply[1] == deny && -z $reply[2] ]]
print defer >"$SHELLFISH_TURN_STATE/decision"
sf_hooks_permission_request "$permission_session" shell call_7 \
  '{"command":"true"}'
[[ $reply[1] == defer && -z $reply[2] ]]
print halt >"$SHELLFISH_TURN_STATE/decision"
if sf_hooks_permission_request "$permission_session" shell call_7 \
    '{"command":"true"}'; then
  fail 'permission halt without a decision was accepted'
fi
[[ $SF_HOOK_ERROR == 'permission_request hook script returned invalid decision' ]]
print malformed >"$SHELLFISH_TURN_STATE/decision"
if sf_hooks_permission_request "$permission_session" shell call_7 \
    '{"command":"true"}'; then
  fail 'malformed permission decision was accepted'
fi
[[ $SF_HOOK_ERROR == 'permission_request hook script returned invalid decision' ]]
sf_session_close
sf_hooks_turn_state_cleanup

# Exit 10 continues the permission chain, so a later halting fd-3 decision wins.
typeset permission_chain_session="$tmp/permission-chain-session.jsonl"
make_script permission_chain_skip 'exit 10'
typeset permission_chain_skip=$script
make_script permission_chain_decide \
  'decision=$(<"$SHELLFISH_TURN_STATE/chain-decision"); if [[ $decision == allow ]]; then print -rn -u3 -- '\''{"action":"allow"}'\''; else print -rn -u3 -- '\''{"action":"deny","reason":"chain denied"}'\''; fi; exit 11'
typeset permission_chain_decide=$script
typeset permission_runtime=$SF_TEST_RUNTIME
SF_TEST_RUNTIME=$(jq -c \
  --arg skip "$permission_chain_skip" --arg decide "$permission_chain_decide" \
  '.harness.permission_request=[$skip,$decide]' <<<"$SF_TEST_RUNTIME")
sf_test_session "$permission_chain_session"
sf_session_open "$permission_chain_session"
sf_hooks_turn_state_create
typeset -gx SHELLFISH_TURN_ID=1
print allow >"$SHELLFISH_TURN_STATE/chain-decision"
sf_hooks_permission_request "$permission_chain_session" shell call_8 \
  '{"command":"true"}'
[[ $reply[1] == allow && -z $reply[2] ]]
print deny >"$SHELLFISH_TURN_STATE/chain-decision"
sf_hooks_permission_request "$permission_chain_session" shell call_8 \
  '{"command":"true"}'
[[ $reply[1] == deny && $reply[2] == 'chain denied' ]]
sf_session_close
sf_hooks_turn_state_cleanup
SF_TEST_RUNTIME=$permission_runtime

typeset plain_session="$tmp/plain-session.jsonl"
SF_TEST_RUNTIME=$(jq 'del(.harness.user_prompt_submit)' <<<"$SF_TEST_RUNTIME")
sf_test_session "$plain_session"
sf_session_open "$plain_session"
sf_session_close
sf_hooks_turn_state_create
run_prompt_hook ordinary "$plain_session"
[[ ${#reply} == 1 && $reply[1] == proceed && -z $SF_HOOK_ERROR ]]
(( $(wc -l <"$plain_session") == 1 ))
sf_hooks_turn_state_cleanup

# Stop hooks observe a completed assistant. A status-0 hook's stdout is
# discarded; only a skipped completion commits stdout as continuation feedback,
# and a skip without feedback is a contract error.
make_script stop '[[ $# == 2 && $1 == stop && $2 == "$STOP_ATTEMPT" && "$(cat)" == "$STOP_INPUT" ]] || exit 1; print -rn -u2 -- local; [[ -z $STOP_STDOUT ]] || print -rn -- feedback; [[ -z $STOP_SKIP ]] || exit 10'
typeset stop_script=$script
SF_TEST_RUNTIME=$(jq -c --arg script "$stop_script" \
  '.harness.stop=[$script]' <<<"$SF_TEST_RUNTIME")
typeset stop_session="$tmp/stop-session.jsonl"
sf_test_session "$stop_session"
sf_session_open "$stop_session"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"hi"}]}'
sf_session_append '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}'
sf_session_close
sf_hooks_turn_state_create
sf_session_open "$stop_session"
STOP_ATTEMPT=1 STOP_INPUT=hi STOP_STDOUT=1 sf_hooks_stop "$stop_session" hi 1
[[ $reply[1] == finish && $SF_HOOK_SCRIPT_RESULTS[4] == local ]]
sf_session_close
(( $(wc -l <"$stop_session") == 3 ))

sf_session_open "$stop_session"
STOP_ATTEMPT=2 STOP_INPUT=hi STOP_SKIP=1 STOP_STDOUT=1 \
  sf_hooks_stop "$stop_session" hi 2
[[ $reply[1] == continue && $SF_HOOK_SCRIPT_RESULTS[4] == local ]]
sf_session_close
jq -e -s '.[-1] == {type:"context",hook:"stop",script:"stop",content:"feedback"}' \
  "$stop_session" >/dev/null

sf_session_open "$stop_session"
if STOP_ATTEMPT=3 STOP_INPUT=hi STOP_SKIP=1 sf_hooks_stop "$stop_session" hi 3; then
  fail 'stop skip without feedback was accepted'
fi
[[ $SF_HOOK_ERROR == 'stop hook script skipped completion without feedback' ]]
sf_session_close
sf_hooks_turn_state_cleanup
assert_no_hook_captures
