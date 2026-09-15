#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh

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
  include "lib/runtime/schema";
  canonical_session_header(1) and
  .profile.request.model == "test-model"
' <<<"$header" >/dev/null
[[ $SF_SESSION[turn_id] == 1 && $SF_SESSION[cwd] == "$PWD" &&
   $SF_SESSION[model] == test-model ]]

sf_session_append "$session" '{"type":"user","content":[{"type":"text","text":"hello"}]}'
sf_session_append "$session" '{"type":"assistant","stop":"end","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}'
sf_session_reset
(( $(wc -l <"$session") == 3 ))

# Runtime updates preserve transcript bytes and file mode.
typeset transcript_before updated_before
transcript_before=$(tail -n +2 "$session")
sf_session_begin_turn "$session"
sf_session_update "$session" '{"harness":{"sandbox_read_paths":["/tmp/reference"]}}' ||
  fail "$SF_SESSION_ERROR"
[[ $REPLY == 1 ]]
typeset request_update='{"harness":{"sandbox_write_paths":["/tmp/reference"]},"profile":{"request":{"effort":null}}}'
sf_session_update "$session" "$request_update" ||
  fail "$SF_SESSION_ERROR"
[[ $REPLY == 1 ]]
jq -e '
  .harness.sandbox_read_paths == ["/tmp/reference"] and
  .harness.sandbox_write_paths == ["/tmp/reference"] and
  .profile.request.effort == null
' <<<"$SF_SESSION[runtime]" >/dev/null
[[ $(tail -n +2 "$session") == "$transcript_before" ]]
[[ $(stat -f '%Lp' "$session") == 600 ]]
updated_before=$(cat "$session")
sf_session_update "$session" '{"harness":{"sandbox_write_paths":["/tmp/reference"]}}'
[[ $REPLY == 0 && $(cat "$session") == "$updated_before" ]]
sf_session_update "$session" '{"harness":{"sandbox_write_paths":[]}}'
[[ $REPLY == 1 ]]
jq -e '
  .harness.sandbox_read_paths == ["/tmp/reference"] and
  .harness.sandbox_write_paths == []
' <<<"$SF_SESSION[runtime]" >/dev/null
sf_session_update "$session" '{"harness":{"sandbox_write_paths":[]}}'
[[ $REPLY == 0 ]]
updated_before=$(cat "$session")
if sf_session_update "$session" '{"cwd":"/tmp"}'; then
  fail 'session metadata update succeeded'
fi
if sf_session_update "$session" '{"harness":{"sandbox":null}}'; then
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

# Recovery repairs the durable transcript.
typeset recovery_sync="$tmp/recovery-sync.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$recovery_sync"
sf_session_begin_turn "$recovery_sync"
sf_session_append "$recovery_sync" '{"type":"user","content":[{"type":"text","text":"partial"}]}'
print -rn -- '{"type":"user"' >>"$recovery_sync"
sf_session_resync_turn "$recovery_sync"
assert_equal '{"type":"error","user_text":"Turn interrupted."}' "$REPLY"
sf_session_reset
jq -e -s 'length == 3 and .[-1] == {type:"error",user_text:"Turn interrupted."}' \
  "$recovery_sync" >/dev/null

# Recovery reloads complete durable writes.
typeset recovery_complete="$tmp/recovery-complete.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$recovery_complete"
sf_session_begin_turn "$recovery_complete"
sf_session_append "$recovery_complete" '{"type":"user","content":[{"type":"text","text":"complete"}]}'
print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"done"}]}' \
  >>"$recovery_complete"
sf_session_resync_turn "$recovery_complete"
[[ -z $REPLY ]] || fail 'complete durable turn was recovered as interrupted'
(( ${#SF_SESSION_RECORDS} == 3 )) || fail 'resync did not reload the complete durable turn'
sf_session_resync_turn "$recovery_complete" 'stop hook failed' 1
assert_equal '{"type":"error","user_text":"stop hook failed"}' "$REPLY"
sf_session_reset
jq -e -s 'length == 4 and .[-1] == {type:"error",user_text:"stop hook failed"}' \
  "$recovery_complete" >/dev/null

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
[[ $SF_SESSION[turn_id] == 2 && -z $SF_SESSION_RECOVERY_NEEDED && -z $REPLY ]]
(( ${#SF_SESSION_RECORDS} == 5 ))
sf_session_reset

# Opening preserves valid session bytes.
typeset exact="$tmp/exact.jsonl" exact_before="$tmp/exact-before.jsonl" exact_header
exact_header=$(head -n 1 "$SF_TEST_SESSIONS/header-only.jsonl")
print -r -- "  $exact_header  " >"$exact"
cp "$exact" "$exact_before"
sf_session_begin_turn "$exact"
assert_equal fake-model "$SF_SESSION[model]"
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

# Opening rejects noncanonical records.
typeset invalid_record="$tmp/invalid-record.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$invalid_record"
print -r -- '{"type":"hook_result","hook":"session_start","id":"","name":"bad","input":"","exit_code":0}' >>"$invalid_record"
if sf_session_begin_turn "$invalid_record"; then
  fail 'session with an invalid durable record was accepted'
fi

# Readers trim incomplete trailing records.
before=$(head -n 3 "$session")
print -rn -- '{"type":"user"' >>"$session"
sf_session_begin_turn "$session"
[[ $(cat "$session") == "$before" ]]
sf_session_reset

# Recovery closes an interrupted tool continuation without inventing outcomes.
typeset interrupted_tools="$tmp/interrupted-tools.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$interrupted_tools"
sf_session_begin_turn "$interrupted_tools"
sf_session_append "$interrupted_tools" '{"type":"user","content":[{"type":"text","text":"run"}]}'
sf_session_append "$interrupted_tools" '{"type":"assistant","stop":"tool_calls","content":[]}'
sf_session_append "$interrupted_tools" '{"type":"tool_result","call_id":"call_1","name":"shell","input":{},"stdout":"done","stderr":"","exit_code":0}'
sf_session_reset
sf_session_begin_turn "$interrupted_tools"
sf_session_append "$interrupted_tools" '{"type":"user","content":[{"type":"text","text":"next"}]}'
sf_session_reset
jq -e -s '
  .[-2] == {type:"error",user_text:"Turn interrupted."} and
  (.[-3] | .type == "tool_result" and .call_id == "call_1" and .exit_code == 0) and
  .[-1].type == "user" and .[-1].content[0].text == "next"
' "$interrupted_tools" >/dev/null

# Queue recovery compares only results below the owning assistant response.
typeset repeated_calls="$tmp/repeated-calls.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$repeated_calls"
sf_session_begin_turn "$repeated_calls"
sf_session_append "$repeated_calls" '{"type":"user","content":[{"type":"text","text":"first"}]}'
sf_session_append "$repeated_calls" '{"type":"assistant","stop":"tool_calls","content":[]}'
sf_session_append "$repeated_calls" '{"type":"tool_result","call_id":"call_1","name":"shell","input":{},"stdout":"done","stderr":"","exit_code":0}'
sf_session_append "$repeated_calls" '{"type":"assistant","stop":"end","content":[]}'
sf_session_append "$repeated_calls" '{"type":"user","content":[{"type":"text","text":"second"}]}'
sf_session_append "$repeated_calls" '{"type":"assistant","stop":"tool_calls","content":[]}'
sf_session_resync_turn "$repeated_calls" interrupted 1 \
  '{"id":"call_1","name":"shell","input":{},"execution_input":{}}' call_1
sf_session_reset
jq -e -s '
  ([.[] | select(.type == "tool_result" and .call_id == "call_1")] | length) == 2 and
  .[-2].stderr == "tool call interrupted" and .[-1].type == "error"
' "$repeated_calls" >/dev/null

# A result committed before queue removal is not duplicated during cleanup.
typeset committed_result="$tmp/committed-result.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$committed_result"
sf_session_begin_turn "$committed_result"
sf_session_append "$committed_result" '{"type":"user","content":[{"type":"text","text":"run"}]}'
sf_session_append "$committed_result" '{"type":"assistant","stop":"tool_calls","content":[]}'
sf_session_append "$committed_result" '{"type":"tool_result","call_id":"call_2","name":"shell","input":{},"stdout":"done","stderr":"","exit_code":0}'
sf_session_resync_turn "$committed_result" interrupted 1 \
  '{"id":"call_2","name":"shell","input":{},"execution_input":{}}' call_2
sf_session_reset
jq -e -s '
  ([.[] | select(.type == "tool_result" and .call_id == "call_2")] | length) == 1 and
  .[-1].type == "error"
' "$committed_result" >/dev/null

# Invalid transitions fail on open.
cp "$SF_TEST_SESSIONS/invalid-transition.jsonl" "$tmp/invalid-transition.jsonl"
if sf_session_begin_turn "$tmp/invalid-transition.jsonl"; then
  fail 'invalid transition fixture was accepted'
fi

# Interrupted users allow another turn.
typeset interrupted="$tmp/interrupted.jsonl"
cp "$SF_TEST_SESSIONS/interrupted.jsonl" "$interrupted"
sf_session_begin_turn "$interrupted"
assert_equal '{"type":"error","user_text":"Turn interrupted."}' "$REPLY"
sf_session_append "$interrupted" '{"type":"user","content":[{"type":"text","text":"next"}]}'
sf_session_reset
