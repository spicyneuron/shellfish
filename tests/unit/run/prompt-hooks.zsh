#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh

typeset stream
sf_test_tmp exec-prompt-hooks
export XDG_STATE_HOME="$tmp/state"
sf_test_runtime
export SF_TEST_BACKEND_DELAY=0

# Exec derives the turn ID and owns user_prompt_submit script decisions.
typeset prompt_script="$tmp/prompt-hook"
cat >"$prompt_script" <<'ZSH'
#!/usr/bin/env zsh
prompt=$(cat)
[[ $1 == user_prompt_submit && $SHELLFISH_TURN_ID == 1 ]] || exit 2
case $prompt in
  /decline)
    print -rn -- 'declined context'
    print -r -u2 -- 'declined display'
    exit 10
    ;;
  /handoff)
    print -rn -- 'handoff context'
    print -rn -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","next.jsonl"]}'
    exit 11
    ;;
  /update)
    print -rn -- 'update context'
    print -rn -u3 -- '{"action":"session_update","patch":{"harness":{"sandbox_write_paths":["/tmp/reference"]}}}'
    exit 11
    ;;
  /fail)
    print -r -u2 -- 'prompt failure'
    exit 1
    ;;
  /overflow)
    printf '%*s' "$(( SHELLFISH_MAX_CAPTURE_BYTES + 1 ))" '' >&2
    ;;
  /slow)
    trap '' TERM
    : >"$PROMPT_MARKER"
    sleep 2
    : >"$PROMPT_EXIT_MARKER"
    ;;
  *)
    print -rn -- 'accepted context'
    print -rn -u3 -- '{"state":[{"name":"prompt/status","value":"accepted"}]}'
    ;;
esac
ZSH
chmod +x "$prompt_script"
SF_TEST_RUNTIME=$(jq -c --arg script "$prompt_script" \
  '.harness.user_prompt_submit=[{command:$script,display:"",environment:[]}]' <<<"$SF_TEST_RUNTIME")

typeset prompt_session="$tmp/prompt.jsonl"
sf_test_session "$prompt_session"
stream=$(sf_test_turn accepted "$prompt_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "_notice") | not) and
  ($events | all(has("context") | not)) and
  ($events | map(select(.type == "state" or .type == "context" or .type == "user")) |
    map(.type)) == ["state","context","user"] and
  ($events | map(select(.type == "context")))[0].content == "accepted context" and
  ($events | map(select(.type == "user")))[0].content[0].text == "accepted" and
  ($events | map(select(.type == "_assistant_start")) | length) == 1
' >/dev/null

typeset decline_session="$tmp/decline.jsonl"
sf_test_session "$decline_session"
stream=$(sf_test_turn /decline "$decline_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_notice"))) as $display |
  ($events | map(select(.type == "context")))[0].content == "declined context" and
  ($display | length) == 1 and
  ($display[0] | .text == "declined display\n" and .complete == true) and
  ($events | any(.type == "_assistant_start") | not) and
  ($events | any(.type == "user") | not)
' >/dev/null

typeset handoff_session="$tmp/handoff.jsonl"
sf_test_session "$handoff_session"
stream=$(sf_test_turn /handoff "$handoff_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "user") | not) and
  ($events | any(.type == "_assistant_start") | not) and
  $events[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]}
' >/dev/null

typeset update_session="$tmp/update.jsonl"
sf_test_session "$update_session"
stream=$(sf_test_turn /update "$update_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "user") | not) and
  ($events | any(.type == "_assistant_start") | not) and
  $events[-1].type == "_session_update" and
  $events[-1].runtime.harness.sandbox_write_paths == ["/tmp/reference"]
' >/dev/null
jq -e -s '
  .[0].harness.sandbox_write_paths == ["/tmp/reference"] and
  .[1] == {type:"context",hook:"user_prompt_submit",script:"prompt-hook",
    content:"update context"}
' "$update_session" >/dev/null

typeset failure_session="$tmp/prompt-failure.jsonl"
sf_test_session "$failure_session"
stream=$(sf_test_turn /fail "$failure_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "user") | not) and
  ($events | any(.type == "_assistant_start") | not) and
  $events[0].type == "_notice" and $events[0].complete == true and
  ($events[-1] | .level == "error" and (.text | contains("prompt-hook")))
' >/dev/null

typeset overflow_session="$tmp/prompt-overflow.jsonl"
sf_test_session "$overflow_session"
stream=$(sf_test_turn /overflow "$overflow_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_notice" and .level == "info"))) as $display |
  ($display | length) == 0 and
  ($events[-1] | .type == "_notice" and .level == "error" and
    (.text | contains("hook script output exceeds capture limit")))
' >/dev/null

typeset cancel_session="$tmp/prompt-cancel.jsonl"
typeset cancel_stream="$tmp/prompt-cancel.stream"
export PROMPT_MARKER="$tmp/prompt-active"
export PROMPT_EXIT_MARKER="$tmp/prompt-exit"
# A declared display announces the script for as long as it runs.
SF_TEST_RUNTIME=$(jq -c '.harness.user_prompt_submit[0].display="Working…"' \
  <<<"$SF_TEST_RUNTIME")
sf_test_session "$cancel_session"
integer records=$(wc -l <"$cancel_session")
# A private temp root, since the suite shares one and runs files concurrently.
typeset cancel_temp="$tmp/cancel-temp"
mkdir -p "$cancel_temp"
TMPDIR="$cancel_temp" "$ROOT/bin/shellfish" run --jsonl --session "$cancel_session" \
  < <(print -r -- '{"type":"user","content":[{"type":"text","text":"/slow"}]}') \
  >"$cancel_stream" &
integer pid=$! cancel_status=0 waited=0
while (( waited++ < 50 )) && [[ ! -e $PROMPT_MARKER ]]; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'user_prompt_submit hook script did not start'
waited=0
while (( waited++ < 50 )) && ! jq -se 'any(.text == "Working…")' \
    "$cancel_stream" >/dev/null 2>&1; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'user_prompt_submit display was not announced'
jq -eRn '
  [inputs | fromjson] == [{type:"_notice",level:"info",source:"user_prompt_submit",
    title:$script,text:"Working…",complete:false}]
' --arg script "$prompt_script" <"$cancel_stream" >/dev/null
kill -TERM "$pid"
wait "$pid" || cancel_status=$?
(( cancel_status == 143 ))
[[ ! -e $PROMPT_EXIT_MARKER ]] || fail 'cancelled user_prompt_submit hook script ran to completion'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "user" or .type == "assistant") | not) and
  ($events | any(.type == "_notice" and .complete) | not)
' <"$cancel_stream" >/dev/null
(( $(wc -l <"$cancel_session") == records )) ||
  fail 'pre-commit cancellation appended a recovery record'
# Process exit sweeps invocation-scoped temporary files.
typeset cancel_root="$cancel_temp/shellfish-$EUID"
typeset category
typeset -a cancel_leftovers=()
for category in turns hooks tools tooltemps backends transport; do
  cancel_leftovers+=( "$cancel_root/$category"/*(N) )
done
(( ! ${#cancel_leftovers} )) ||
  fail "cancelled turn left temporary files: ${(j:, :)cancel_leftovers:t}"
