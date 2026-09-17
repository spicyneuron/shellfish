#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh

typeset session header before
sf_test_tmp session
session="$tmp/session.jsonl"
sf_test_runtime

# Default sessions use the state directory.
typeset -g XDG_STATE_HOME="$tmp/state"
sf_session_select_path
[[ $REPLY == "$tmp/state/shellfish/sessions/"*.jsonl ]]
[[ $(stat -f %Lp "$REPLY:h") == 700 ]]

# Prepared sessions initialize turn state.
sf_session_prepare "$SF_TEST_RUNTIME"
sf_test_install_prepared "$session"
sf_session_begin_turn "$session"
jq -e '.profile.request.model == "test-model" and .backend.env_file == ""' \
  <<<"$SF_SESSION[runtime]" >/dev/null
header=$(head -n 1 "$session")
jq -e -L "$ROOT" '
  include "lib/runtime";
  canonical_session_header(1) and
  .runtime.profile.request.model == "test-model"
' <<<"$header" >/dev/null
[[ $SF_SESSION[turn_id] == 1 && $SF_SESSION[cwd] == "$PWD" ]]

sf_session_append "$session" '{"type":"user","content":[{"type":"text","text":"hello"}]}'
sf_session_append "$session" '{"type":"assistant","stop":"end","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}'
sf_session_reset
(( $(wc -l <"$session") == 3 ))

# An update carries the complete replacement runtime, and preserves transcript
# bytes and file mode.
typeset transcript_before updated_before granted denied
transcript_before=$(tail -n +2 "$session")
sf_session_begin_turn "$session"
granted=$(jq -c '.harness.sandbox_read_paths=["/tmp/reference"] |
  .harness.sandbox_write_paths=["/tmp/reference"] |
  .profile.request.effort=null' <<<"$SF_TEST_RUNTIME") || fail 'cannot build the update'
denied=$(jq -c '.harness.sandbox_write_paths=[]' <<<"$granted") || fail 'cannot build the update'
sf_session_update "$session" "$granted" || fail "$SF_SESSION_ERROR"
jq -e '
  .harness.sandbox_read_paths == ["/tmp/reference"] and
  .harness.sandbox_write_paths == ["/tmp/reference"] and
  .profile.request.effort == null
' <<<"$SF_SESSION[runtime]" >/dev/null
[[ $(tail -n +2 "$session") == "$transcript_before" ]]
[[ $(stat -f '%Lp' "$session") == 600 ]]
# An unchanged runtime rewrites nothing.
updated_before=$(cat "$session")
sf_session_update "$session" "$granted"
[[ $(cat "$session") == "$updated_before" ]]
sf_session_update "$session" "$denied"
jq -e '
  .harness.sandbox_read_paths == ["/tmp/reference"] and
  .harness.sandbox_write_paths == []
' <<<"$SF_SESSION[runtime]" >/dev/null
updated_before=$(cat "$session")
if sf_session_update "$session" "$(jq -c '.harness.sandbox=null' <<<"$denied")"; then
  fail 'invalid runtime update succeeded'
fi
[[ $(cat "$session") == "$updated_before" ]]
sf_session_reset
sf_session_read_runtime "$session"
jq -e '
  .harness.sandbox_read_paths == ["/tmp/reference"] and
  .harness.sandbox_write_paths == []
' <<<"$REPLY" >/dev/null
if sf_session_update "$session" '{}'; then
  fail 'session update on a closed session succeeded'
fi

# Reopening restores the next turn.
sf_session_begin_turn "$session"
[[ $SF_SESSION[turn_id] == 2 ]]
typeset -a reopened=( "${(@f)$(<"$session")}" )
(( ${#SF_SESSION_RECORDS} == 3 ))
assert_equal "${(j:\n:)reopened}" "${(j:\n:)SF_SESSION_RECORDS}"
sf_session_reset

# Failed appends do not alter the in-memory record view.
typeset write_failure="$tmp/write-failure.jsonl"
sf_session_prepare "$SF_TEST_RUNTIME"
sf_test_install_prepared "$write_failure"
sf_session_begin_turn "$write_failure"
integer record_count=${#SF_SESSION_RECORDS}
mv "$write_failure" "$write_failure.saved"
mkdir "$write_failure"
if sf_session_append "$write_failure" '{"type":"user","content":[{"type":"text","text":"not written"}]}'; then
  fail 'append to an unavailable session file succeeded'
fi
(( ${#SF_SESSION_RECORDS} == record_count )) ||
  fail 'failed append changed the in-memory session'
rmdir "$write_failure"
mv "$write_failure.saved" "$write_failure"
sf_session_reset

# State survives reopening.
typeset state_session="$tmp/state-session.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$state_session"
print -r -- '{"type":"state","name":"git/identity","value":"first"}' >>"$state_session"
print -r -- '{"type":"user","content":[{"type":"text","text":"hello"}]}' \
  >>"$state_session"
print -r -- '{"type":"state","name":"git/identity","value":null}' >>"$state_session"
print -r -- '{"type":"assistant","stop":"end","content":[]}' \
  >>"$state_session"
sf_session_begin_turn "$state_session"
[[ $SF_SESSION[turn_id] == 2 && -z $REPLY ]]
(( ${#SF_SESSION_RECORDS} == 5 ))
sf_session_reset

# Opening preserves valid session bytes.
typeset exact="$tmp/exact.jsonl" exact_before="$tmp/exact-before.jsonl" exact_header
exact_header=$(head -n 1 "$SF_TEST_SESSIONS/header-only.jsonl")
print -r -- "  $exact_header  " >"$exact"
cp "$exact" "$exact_before"
sf_session_begin_turn "$exact"
sf_session_reset
cmp -s "$exact_before" "$exact" || fail 'opening a valid session rewrote its bytes'

# Blank physical lines are invalid despite jq whitespace handling.
typeset blank="$tmp/blank.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$blank"
print >>"$blank"
if sf_session_begin_turn "$blank"; then
  fail 'session with a blank physical line was accepted'
fi
(( ${#SF_SESSION_RECORDS} == 0 ))

# Readers trim incomplete trailing records.
before=$(head -n 3 "$session")
print -rn -- '{"type":"user"' >>"$session"
sf_session_begin_turn "$session"
[[ $(cat "$session") == "$before" ]]
sf_session_reset

# Reopening settles unresolved calls as unknown outcomes and closes the turn.
typeset unresolved="$tmp/unresolved.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$unresolved"
print -rl -- \
  '{"type":"user","content":[{"type":"text","text":"run"}]}' \
  '{"type":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"shell","input":{"command":"ls"}},{"type":"tool_call","id":"call_2","name":"shell","input":{"command":"pwd"}}]}' \
  '{"type":"tool_result","id":"call_1","name":"shell","input":{"command":"ls"},"exit_code":0,"model_text":"out"}' \
  >>"$unresolved"
sf_session_begin_turn "$unresolved"
print -r -- "$REPLY" | jq -se '. == [
  {type:"tool_result",id:"call_2",name:"shell",input:{command:"pwd"},exit_code:126,
   user_text:"tool call outcome unknown",model_text:"tool call outcome unknown"},
  {type:"error",user_text:"Turn interrupted."}
]' >/dev/null || fail 'reopening did not close the turn with fixed outcomes'
(( ${#SF_SESSION_RECORDS} == 6 )) || fail 'recovery did not append to the durable view'
sf_session_reset
jq -e -s '.[3].model_text == "out"' "$unresolved" >/dev/null ||
  fail 'recovery rewrote a known outcome'
tail -n +2 "$unresolved" | jq -L "$ROOT" -sce 'include "lib/session"; session_load' \
  >/dev/null || fail 'recovery left an invalid transcript'
