#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source session/main.zsh hooks.zsh

typeset stream
sf_test_tmp exec-prompt-hooks
export XDG_STATE_HOME="$tmp/state"
sf_test_runtime
export SF_TEST_BACKEND_DELAY=0

# Exec derives the turn ID under lock and owns prompt-hook decisions.
typeset prompt_hook="$tmp/prompt-hook"
cat >"$prompt_hook" <<'ZSH'
#!/usr/bin/env zsh
prompt=$(cat)
[[ $1 == user_prompt_submit && $SHELLFISH_TURN_ID == 1 ]] || exit 2
case $prompt in
  /decline)
    print -rn -- 'declined context'
    print -rn -u2 -- 'declined display'
    exit 10
    ;;
  /handoff)
    print -rn -- 'handoff context'
    print -rn -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","next.jsonl"]}'
    exit 11
    ;;
  /fail)
    print -rn -u2 -- 'prompt failure'
    exit 1
    ;;
  /slow)
    trap '' TERM
    : >"$PROMPT_MARKER"
    sleep 2
    : >"$PROMPT_EXIT_MARKER"
    ;;
  *) print -rn -- 'accepted context' ;;
esac
ZSH
chmod +x "$prompt_hook"
SF_TEST_RUNTIME=$(jq -c --arg hook "$prompt_hook" \
  '.harness.user_prompt_submit=[$hook]' <<<"$SF_TEST_RUNTIME")

typeset prompt_session="$tmp/prompt.jsonl"
sf_test_session "$prompt_session"
stream=$(sf_test_turn accepted "$prompt_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "context")))[0].content == "accepted context" and
  ($events | map(select(.role == "user")))[0].content[0].text == "accepted" and
  ($events | map(select(.type == "_backend_request_start")) | length) == 1
' >/dev/null

typeset decline_session="$tmp/decline.jsonl"
sf_test_session "$decline_session"
stream=$(sf_test_turn /decline "$decline_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "context")))[0].content == "declined context" and
  ($events | map(select(.type == "_hook_display")))[0].text == "declined display" and
  ($events | any(.type == "_backend_request_start") | not) and
  ($events | any(.role == "user") | not)
' >/dev/null

typeset handoff_session="$tmp/handoff.jsonl"
sf_test_session "$handoff_session"
stream=$(sf_test_turn /handoff "$handoff_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.role == "user") | not) and
  ($events | any(.type == "_backend_request_start") | not) and
  $events[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]}
' >/dev/null

typeset failure_session="$tmp/prompt-failure.jsonl"
sf_test_session "$failure_session"
stream=$(sf_test_turn /fail "$failure_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.role == "user") | not) and
  ($events | any(.type == "_backend_request_start") | not) and
  ($events[-1].message | contains("prompt-hook"))
' >/dev/null

typeset cancel_session="$tmp/prompt-cancel.jsonl"
typeset cancel_stream="$tmp/prompt-cancel.stream"
export PROMPT_MARKER="$tmp/prompt-active"
export PROMPT_EXIT_MARKER="$tmp/prompt-exit"
sf_test_session "$cancel_session"
integer records=$(wc -l <"$cancel_session")
# A private temp root, since the suite shares one and runs files concurrently.
typeset cancel_temp="$tmp/cancel-temp"
mkdir -p "$cancel_temp"
TMPDIR="$cancel_temp" "$ROOT/bin/shellfish" exec --jsonl --session "$cancel_session" \
  < <(print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"/slow"}]}') \
  >"$cancel_stream" &
integer pid=$! cancel_status=0 waited=0
while (( waited++ < 50 )) && [[ ! -e $PROMPT_MARKER ]]; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'prompt hook did not start'
kill -TERM "$pid"
wait "$pid" || cancel_status=$?
(( cancel_status == 143 ))
[[ ! -e $PROMPT_EXIT_MARKER ]] || fail 'cancelled prompt hook ran to completion'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.role == "user" or .role == "assistant") | not)
' <"$cancel_stream" >/dev/null
(( $(wc -l <"$cancel_session") == records )) ||
  fail 'pre-commit cancellation appended a recovery record'
assert_session_unlocked "$cancel_session"
# Process exit sweeps transient turn and hook files. Session state remains.
typeset cancel_root="$cancel_temp/shellfish-$EUID"
typeset category
typeset -a cancel_leftovers=()
for category in turns hooks tools backends transport; do
  cancel_leftovers+=( "$cancel_root/$category"/*(N) )
done
(( ! ${#cancel_leftovers} )) ||
  fail "cancelled turn left temporary files: ${(j:, :)cancel_leftovers:t}"
[[ -d $cancel_root/sessions/prompt-cancel ]]
