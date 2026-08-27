#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source session/main.zsh

typeset session header before stored_runtime
sf_test_tmp session
session="$tmp/session.jsonl"
sf_test_runtime

typeset cwd_canonical
cwd_canonical=$(pwd -P)

sf_session_select_path "$tmp/relative.jsonl"
[[ $REPLY == "$tmp/relative.jsonl" ]]

typeset -g XDG_STATE_HOME="$tmp/state"
sf_session_select_path
[[ $REPLY == "$tmp/state/shellfish/sessions/"*.jsonl ]]
[[ $(stat -f %Lp "$REPLY:h") == 700 ]]

typeset session_dir=$REPLY:h

make_header() {
  local session_cwd=$1 profile_name=$2 model_name=$3
  jq -cn --arg cwd "$session_cwd" --arg profile "$profile_name" --arg model "$model_name" '
    {
      type: "session",
      format_version: 1,
      cwd: $cwd,
      created: "2026-08-18T00:00:00Z",
      profile: {name: $profile, backend: "openai", harness: "", request: {model: $model}},
      backend: {name: "openai", command: "/bin/run", endpoint: "https://example.invalid"}
    }
  '
}

make_header "$cwd_canonical" default gpt-4o >"$session_dir/session1.jsonl"
touch -t 202608180100 "$session_dir/session1.jsonl"
make_header "$cwd_canonical" work claude-3 >"$session_dir/session2.jsonl"
touch -t 202608180200 "$session_dir/session2.jsonl"
make_header /nonexistent/other/dir default gpt-4o >"$session_dir/other_cwd.jsonl"
touch -t 202608180300 "$session_dir/other_cwd.jsonl"
print -r -- '{"not":"a session header"}' >"$session_dir/corrupt.jsonl"

sf_session_find 0
(( ${#SF_SESSION_MATCHES} == 2 ))
[[ $SF_SESSION_MATCHES[1] == "$session_dir/session2.jsonl" ]]
[[ $SF_SESSION_MATCHES[2] == "$session_dir/session1.jsonl" ]]

sf_session_find 1
(( ${#SF_SESSION_MATCHES} == 1 ))
[[ $SF_SESSION_MATCHES[1] == "$session_dir/session2.jsonl" ]]

(
  cd "$tmp"
  if sf_session_find 0 2>/dev/null; then
    fail 'session discovery succeeded with no matches'
  fi
)

# Creation exclusively materializes the validated prefix without a turn lock.
SF_SESSION_PATH=$session
sf_session_prepare "$SF_TEST_RUNTIME"
sf_session_create
(( ${#SF_SESSION_RECORDS} == 1 ))
sf_session_open "$session"
[[ -n $SF_SESSION_LOCK ]]
[[ $(stat -f '%Lp' "$session") == 600 ]]
jq -e '.profile.request.model == "test-model" and .backend.env_file == ""' \
  <<<"$SF_SESSION[runtime]" >/dev/null
stored_runtime=$SF_SESSION[runtime]
if sf_session_open "$tmp/other.jsonl"; then
  fail 'nested session open succeeded'
fi
[[ $SF_SESSION_PATH == "$session" && -n $SF_SESSION_LOCK ]]
if SF_ROOT=$ROOT zsh -fc 'source "$SF_ROOT/lib/session/main.zsh"; sf_session_open "$1"' -- "$session"; then
  fail 'a second process acquired the held session lock'
fi
header=$(head -n 1 "$session")
(( ${#SF_SESSION_RECORDS} == 1 ))
assert_equal "$header" "$SF_SESSION_RECORDS[1]"
jq -e -L "$ROOT/lib" '
  include "runtime/schema";
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
sf_session_close
(( ${#SF_SESSION[@]} == 0 && ${#SF_SESSION_RECORDS} == 0 ))
assert_session_unlocked "$session"
(( $(wc -l <"$session") == 3 ))

typeset broken="$tmp/broken.jsonl"
ln -s "$tmp/missing.jsonl" "$broken"
SF_SESSION_PATH=$broken
if sf_session_prepare "$SF_TEST_RUNTIME"; then
  fail 'prepared creation through a broken symlink'
fi

# Reopening an existing session restores its next turn state.
sf_session_open "$session"
[[ $SF_SESSION[id] == session && $SF_SESSION[turn_id] == 2 ]]
typeset -a reopened=( "${(@f)$(<"$session")}" )
(( ${#SF_SESSION_RECORDS} == 3 ))
assert_equal "${(j:\n:)reopened}" "${(j:\n:)SF_SESSION_RECORDS}"
sf_session_close

# A failed durable append does not extend the synchronized record view.
typeset write_failure="$tmp/write-failure.jsonl"
SF_SESSION_PATH=$write_failure
sf_session_prepare "$SF_TEST_RUNTIME"
sf_session_create
sf_session_open "$write_failure"
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
sf_session_close

# Recovery repairs the durable transcript before inspecting it.
typeset recovery_sync="$tmp/recovery-sync.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$recovery_sync"
sf_session_open "$recovery_sync"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"partial"}]}'
print -rn -- '{"type":"message"' >>"$recovery_sync"
sf_session_recover_turn
[[ $(jq -r '.content[0].text' <<<"$REPLY") == 'Turn interrupted.' ]]
sf_session_close
jq -e -s 'length == 3 and .[-1].role == "assistant" and .[-1].stop == "end"' \
  "$recovery_sync" >/dev/null

# Recovery reloads complete writes missing from the in-memory view.
typeset recovery_complete="$tmp/recovery-complete.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$recovery_complete"
sf_session_open "$recovery_complete"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"complete"}]}'
print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"done"}]}' \
  >>"$recovery_complete"
sf_session_recover_turn
[[ -z $REPLY ]]
sf_session_close
jq -e -s 'length == 3 and .[-1].content[0].text == "done"' "$recovery_complete" >/dev/null

# Valid records retain their exact physical representation after validation.
typeset exact="$tmp/exact.jsonl" exact_header
exact_header=$(head -n 1 "$SF_TEST_SESSIONS/header-only.jsonl")
print -r -- "  $exact_header  " >"$exact"
sf_session_open "$exact"
assert_equal "  $exact_header  " "$SF_SESSION_RECORDS[1]"
sf_session_close

# Every physical line must contain a record; jq whitespace skipping is not enough.
typeset blank="$tmp/blank.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$blank"
print >>"$blank"
if sf_session_open "$blank"; then
  fail 'session with a blank physical line was accepted'
fi
(( ${#SF_SESSION_RECORDS} == 0 ))

# A supplied resolved runtime replaces the direct-test development header.
typeset configured="$tmp/configured.jsonl"
mkdir "$tmp/system"
printf 'first prompt\n' >"$tmp/system/first.md"
printf 'second prompt\n' >"$tmp/system/second.md"
SF_TEST_RUNTIME=$(jq -c '.profile.request.model="configured-model"' <<<"$stored_runtime")
SF_TEST_SYSTEM_RECORD=$(jq -cn \
  --arg content $'first prompt\n\nsecond prompt' '{type:"system",content:$content}')
SF_SESSION_PATH=$configured
sf_session_prepare "$SF_TEST_RUNTIME" "$SF_TEST_SYSTEM_RECORD"
sf_session_create
jq -e -s '.[0].profile.request.model == "configured-model"' "$configured" >/dev/null
jq -e -s '
  length == 2 and
  .[1] == {type:"system",content:"first prompt\n\nsecond prompt"}
' "$configured" >/dev/null

# System content is frozen when the session is materialized, not read again.
printf 'changed\n' >"$tmp/system/first.md"
sf_session_open "$configured"
sf_session_close
jq -e -s '.[1].content == "first prompt\n\nsecond prompt"' "$configured" >/dev/null

SF_TEST_RUNTIME=''
SF_TEST_SYSTEM_RECORD=''

# Opening rejects noncanonical durable records.
typeset invalid_record="$tmp/invalid-record.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$invalid_record"
print -r -- '{"type":"context","tag":"test","hook":"","content":"bad"}' >>"$invalid_record"
if sf_session_open "$invalid_record"; then
  fail 'session with an invalid durable record was accepted'
fi

# A later lock owner removes only an incomplete trailing fragment.
before=$(head -n 3 "$session")
print -rn -- '{"type":"message"' >>"$session"
sf_session_open "$session"
[[ $(cat "$session") == "$before" ]]
sf_session_close

# Static fixtures cover canonical formats the new core must continue to accept.
for fixture in header-only complete tool-complete; do
  cp "$SF_TEST_SESSIONS/$fixture.jsonl" "$tmp/$fixture.jsonl"
  sf_session_open "$tmp/$fixture.jsonl"
  sf_session_close
done

# A provider-order tool sequence remains valid across reopen.
typeset native="$tmp/native.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$native"
sf_session_open "$native"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"run"}]}'
sf_session_append '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"shell","input":{}},{"type":"tool_call","id":"call_2","name":"read_file","input":{}}]}'
sf_session_append '{"type":"message","role":"tool_result","call_id":"call_1","name":"shell","content":"denied","exit_code":126}'
sf_session_append '{"type":"message","role":"tool_result","call_id":"call_2","name":"read_file","content":"bad","exit_code":1}'
sf_session_append '{"type":"message","role":"assistant","stop":"length","content":[{"type":"text","text":"partial"}]}'
sf_session_append '{"type":"context","tag":"stop","hook":"fixture","content":"continue"}'
sf_session_append '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"halted"}]}'
sf_session_close
sf_session_open "$native"
sf_session_close

# Reopening a session interrupted during a tool batch fills its unanswered calls
# and closes the turn with an ordinary assistant message.
typeset interrupted_tools="$tmp/interrupted-tools.jsonl"
cp "$SF_TEST_SESSIONS/header-only.jsonl" "$interrupted_tools"
sf_session_open "$interrupted_tools"
sf_session_append '{"type":"message","role":"user","content":[{"type":"text","text":"run"}]}'
sf_session_append '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"shell","input":{}},{"type":"tool_call","id":"call_2","name":"shell","input":{}}]}'
sf_session_close
sf_session_open "$interrupted_tools"
sf_session_close
jq -e -s '
  .[-3].call_id == "call_1" and .[-3].exit_code == 126 and
  .[-2].call_id == "call_2" and .[-2].exit_code == 126 and
  .[-1].role == "assistant" and .[-1].stop == "end"
' "$interrupted_tools" >/dev/null
cp "$SF_TEST_SESSIONS/invalid-transition.jsonl" "$tmp/invalid-transition.jsonl"
if sf_session_open "$tmp/invalid-transition.jsonl"; then
  fail 'invalid transition fixture was accepted'
fi

# A committed user without an assistant remains valid and is recovered by the
# next mutation owner before another turn begins.
typeset interrupted="$tmp/interrupted.jsonl"
cp "$SF_TEST_SESSIONS/interrupted.jsonl" "$interrupted"
sf_session_open "$interrupted"
[[ -n $REPLY ]]
[[ $(jq -r '.stop' <<<"$REPLY") == end ]]
sf_session_close

# A live owner excludes another process, while its lock is released cleanly.
sf_session_open "$session"
if (
  source "$ROOT/lib/session/main.zsh"
  sf_session_open "$session"
) 2>/dev/null; then
  fail 'competing session owner acquired the lock'
fi
sf_session_close
