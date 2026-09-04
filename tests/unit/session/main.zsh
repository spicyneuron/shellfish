#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh

typeset session header before stored_runtime
sf_test_tmp session
session="$tmp/session.jsonl"
sf_test_runtime

sf_session_select_path "$tmp/relative.jsonl"
[[ $REPLY == "$tmp/relative.jsonl" ]]

typeset -g XDG_STATE_HOME="$tmp/state"
sf_session_select_path
[[ $REPLY == "$tmp/state/shellfish/sessions/"*.jsonl ]]
[[ $(stat -f %Lp "$REPLY:h") == 700 ]]

# Creation exclusively materializes the validated prefix.
SF_SESSION_PATH=$session
sf_session_prepare "$SF_TEST_RUNTIME"
sf_session_create
(( ${#SF_SESSION_RECORDS} == 1 ))
sf_session_begin_turn "$session"
[[ $(stat -f '%Lp' "$session") == 600 ]]
jq -e '.profile.request.model == "test-model" and .backend.env_file == ""' \
  <<<"$SF_SESSION[runtime]" >/dev/null
stored_runtime=$SF_SESSION[runtime]
header=$(head -n 1 "$session")
(( ${#SF_SESSION_RECORDS} == 1 ))
assert_equal "$header" "$SF_SESSION_RECORDS[1]"
jq -e -L "$ROOT" '
  include "lib/runtime/schema";
  canonical_session_header(1) and
  .profile.request.model == "test-model"
' <<<"$header" >/dev/null
[[ $SF_SESSION[id] == session && $SF_SESSION[turn_id] == 1 &&
   $SF_SESSION[cwd] == "$PWD" && $SF_SESSION[model] == test-model ]]

sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"hello"}]}'
(( ${#SF_SESSION_RECORDS} == 2 ))
assert_equal '{"type":"message","role":"user","content":[{"type":"text","text":"hello"}]}' "$SF_SESSION_RECORDS[2]"
sf_session_append '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}'
(( ${#SF_SESSION_RECORDS} == 3 ))
assert_equal '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}' "$SF_SESSION_RECORDS[3]"
sf_session_reset
(( ${#SF_SESSION[@]} == 0 && ${#SF_SESSION_RECORDS} == 0 ))
(( $(wc -l <"$session") == 3 ))

# Runtime updates replace only the header while retaining the transcript,
# restrictive file mode, and synchronized state.
typeset transcript_before updated_before
transcript_before=$(tail -n +2 "$session")
sf_session_begin_turn "$session"
sf_session_update '{"harness":{"sandbox_read_paths":["/tmp/reference"]}}' ||
  fail "$SF_SESSION_ERROR"
[[ $REPLY == 1 ]]
typeset request_update='{"harness":{"sandbox_write_paths":["/tmp/reference"]},"profile":{"request":{"effort":null}}}'
sf_session_update "$request_update" ||
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
sf_session_update '{"harness":{"sandbox_write_paths":["/tmp/reference"]}}'
[[ $REPLY == 0 && $(cat "$session") == "$updated_before" ]]
sf_session_update '{"harness":{"sandbox_write_paths":[]}}'
[[ $REPLY == 1 ]]
jq -e '
  .harness.sandbox_read_paths == ["/tmp/reference"] and
  .harness.sandbox_write_paths == []
' <<<"$SF_SESSION[runtime]" >/dev/null
sf_session_update '{"harness":{"sandbox_write_paths":[]}}'
[[ $REPLY == 0 ]]
updated_before=$(cat "$session")
if sf_session_update '{"cwd":"/tmp"}'; then
  fail 'session metadata update succeeded'
fi
if sf_session_update '{"harness":{"sandbox":null}}'; then
  fail 'invalid runtime update succeeded'
fi
[[ $(cat "$session") == "$updated_before" ]]
sf_session_reset
sf_session_read_runtime "$session"
jq -e '
  .harness.sandbox_read_paths == ["/tmp/reference"] and
  .harness.sandbox_write_paths == []
' <<<"$REPLY" >/dev/null
if sf_session_update '{}'; then
  fail 'session update on a closed session succeeded'
fi

typeset broken="$tmp/broken.jsonl"
ln -s "$tmp/missing.jsonl" "$broken"
SF_SESSION_PATH=$broken
if sf_session_prepare "$SF_TEST_RUNTIME"; then
  fail 'prepared creation through a broken symlink'
fi

# Reopening an existing session restores its next turn state.
sf_session_begin_turn "$session"
[[ $SF_SESSION[id] == session && $SF_SESSION[turn_id] == 2 ]]
typeset -a reopened=( "${(@f)$(<"$session")}" )
(( ${#SF_SESSION_RECORDS} == 3 ))
assert_equal "${(j:\n:)reopened}" "${(j:\n:)SF_SESSION_RECORDS}"
sf_session_reset

# A failed durable append does not extend the synchronized record view.
typeset write_failure="$tmp/write-failure.jsonl"
SF_SESSION_PATH=$write_failure
sf_session_prepare "$SF_TEST_RUNTIME"
sf_session_create
sf_session_begin_turn "$write_failure"
integer record_count
record_count=${#SF_SESSION_RECORDS}
mv "$write_failure" "$write_failure.saved"
mkdir "$write_failure"
if sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"not written"}]}'; then
  fail 'append to an unavailable session file succeeded'
fi
(( ${#SF_SESSION_RECORDS} == record_count ))
rmdir "$write_failure"
mv "$write_failure.saved" "$write_failure"
sf_session_reset

# Recovery repairs the durable transcript before inspecting it.
typeset recovery_sync="$tmp/recovery-sync.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$recovery_sync"
sf_session_begin_turn "$recovery_sync"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"partial"}]}'
print -rn -- '{"type":"message"' >>"$recovery_sync"
sf_session_resync_turn
[[ $(jq -r '.content[0].text' <<<"$REPLY") == 'Turn interrupted.' ]]
sf_session_reset
jq -e -s 'length == 3 and .[-1].role == "assistant" and .[-1].stop == "end"' \
  "$recovery_sync" >/dev/null

# Recovery reloads complete writes missing from the in-memory view.
typeset recovery_complete="$tmp/recovery-complete.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$recovery_complete"
sf_session_begin_turn "$recovery_complete"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"complete"}]}'
print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"done"}]}' \
  >>"$recovery_complete"
sf_session_resync_turn
[[ -z $REPLY ]]
sf_session_reset
jq -e -s 'length == 3 and .[-1].content[0].text == "done"' "$recovery_complete" >/dev/null

# Opening a valid session preserves its bytes and semantic state.
typeset exact="$tmp/exact.jsonl" exact_before="$tmp/exact-before.jsonl" exact_header
exact_header=$(head -n 1 "$SF_TEST_SESSIONS/header-only.jsonl")
print -r -- "  $exact_header  " >"$exact"
cp "$exact" "$exact_before"
sf_session_begin_turn "$exact"
assert_equal fake-model "$SF_SESSION[model]"
sf_session_reset
cmp -s "$exact_before" "$exact" || fail 'opening a valid session rewrote its bytes'

# Every physical line must contain a record; jq whitespace skipping is not enough.
typeset blank="$tmp/blank.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$blank"
print >>"$blank"
if sf_session_begin_turn "$blank"; then
  fail 'session with a blank physical line was accepted'
fi
(( ${#SF_SESSION_RECORDS} == 0 ))

# A supplied resolved runtime replaces the direct-test development header.
typeset configured="$tmp/configured.jsonl"
SF_TEST_RUNTIME=$(jq -c '.profile.request.model="configured-model"' <<<"$stored_runtime")
SF_SESSION_PATH=$configured
sf_session_prepare "$SF_TEST_RUNTIME"
sf_session_create
jq -e -s 'length == 1 and .[0].profile.request.model == "configured-model"' \
  "$configured" >/dev/null

SF_TEST_RUNTIME=''

# Opening rejects noncanonical durable records.
typeset invalid_record="$tmp/invalid-record.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$invalid_record"
print -r -- '{"type":"context","hook":"test","script":"","content":"bad"}' >>"$invalid_record"
if sf_session_begin_turn "$invalid_record"; then
  fail 'session with an invalid durable record was accepted'
fi

# A later reader removes only an incomplete trailing fragment.
before=$(head -n 3 "$session")
print -rn -- '{"type":"message"' >>"$session"
sf_session_begin_turn "$session"
[[ $(cat "$session") == "$before" ]]
sf_session_reset

# Static fixtures cover canonical formats the new core must continue to accept.
for fixture in header-only complete tool-complete; do
  cp "$SF_TEST_SESSIONS/$fixture.jsonl" "$tmp/$fixture.jsonl"
  sf_session_begin_turn "$tmp/$fixture.jsonl"
  sf_session_reset
done

# A provider-order tool sequence remains valid across reopen.
typeset native="$tmp/native.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$native"
sf_session_begin_turn "$native"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"run"}]}'
sf_session_append '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"shell","input":{}},{"type":"tool_call","id":"call_2","name":"read_file","input":{}}]}'
sf_session_append '{"type":"message","role":"tool_result","call_id":"call_1","name":"shell","content":"denied","exit_code":126}'
sf_session_append '{"type":"message","role":"tool_result","call_id":"call_2","name":"read_file","content":"bad","exit_code":1}'
sf_session_append '{"type":"message","role":"assistant","stop":"length","content":[{"type":"text","text":"partial"}]}'
sf_session_append '{"type":"context","hook":"stop","script":"fixture","content":"continue"}'
sf_session_append '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"halted"}]}'
sf_session_reset
sf_session_begin_turn "$native"
sf_session_reset

# Reopening a session interrupted during a tool batch fills its unanswered calls
# and closes the turn with an ordinary assistant message.
typeset interrupted_tools="$tmp/interrupted-tools.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$interrupted_tools"
sf_session_begin_turn "$interrupted_tools"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"run"}]}'
sf_session_append '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"shell","input":{}},{"type":"tool_call","id":"call_2","name":"shell","input":{}}]}'
sf_session_reset
sf_session_begin_turn "$interrupted_tools"
sf_session_reset
jq -e -s '
  .[-3].call_id == "call_1" and .[-3].exit_code == 126 and
  .[-2].call_id == "call_2" and .[-2].exit_code == 126 and
  .[-1].role == "assistant" and .[-1].stop == "end"
' "$interrupted_tools" >/dev/null
cp "$SF_TEST_SESSIONS/invalid-transition.jsonl" "$tmp/invalid-transition.jsonl"
if sf_session_begin_turn "$tmp/invalid-transition.jsonl"; then
  fail 'invalid transition fixture was accepted'
fi

# A committed user without an assistant remains valid and is recovered by the
# next mutation owner before another turn begins.
typeset interrupted="$tmp/interrupted.jsonl"
cp "$SF_TEST_SESSIONS/interrupted.jsonl" "$interrupted"
sf_session_begin_turn "$interrupted"
[[ -n $REPLY ]]
[[ $(jq -r '.stop' <<<"$REPLY") == end ]]
sf_session_reset
