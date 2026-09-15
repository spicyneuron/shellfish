#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/main.zsh libexec/run/hooks.zsh

typeset stream
sf_test_tmp exec-prompt-hooks
export XDG_STATE_HOME="$tmp/state"
sf_test_runtime
export SF_TEST_BACKEND_DELAY=0

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
  '.harness.user_prompt_submit=[{command:$script,environment:[],render:{user_before:"",user_after:"",model_after:"${output.stdout}"}}]' <<<"$SF_TEST_RUNTIME")

# Accepted prompts persist hook context.
typeset prompt_session="$tmp/prompt.jsonl"
sf_test_session "$prompt_session"
stream=$(sf_test_turn accepted "$prompt_session")
print -r -- "$stream" | jq -eRn --arg script "$prompt_script" '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "_hook_activity")) | length) == 1 and
  ($events | map(select(.type == "state" or .type == "hook_result" or .type == "user")) |
    map(.type)) == ["state","hook_result","user"] and
  (($events | map(select(.type == "hook_result")))[0].model_text |
    contains("accepted context")) and
  ($events | map(select(.type == "user")))[0].content[0].text == "accepted" and
  ($events | map(select(.type == "_assistant_start")) | length) == 1
' >/dev/null

# Declined prompts stop before generation.
typeset decline_session="$tmp/decline.jsonl"
sf_test_session "$decline_session"
stream=$(sf_test_turn /decline "$decline_session")
print -r -- "$stream" | jq -eRn --arg executable "$prompt_script" '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "hook_result")))[0] as $result |
  ($result | del(.id,.model_text)) ==
    {type:"hook_result",hook:"user_prompt_submit",name:"prompt-hook",
      input:"/decline",executable:$executable,exit_code:10} and
  ($result.model_text | contains("declined context")) and
  ($events | any(.type == "_assistant_start") | not) and
  ($events | any(.type == "user") | not)
' >/dev/null

# Prompt hooks can hand off execution.
typeset handoff_session="$tmp/handoff.jsonl"
sf_test_session "$handoff_session"
stream=$(sf_test_turn /handoff "$handoff_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "user") | not) and
  ($events | any(.type == "_assistant_start") | not) and
  $events[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]}
' >/dev/null

# Prompt hooks can update sessions.
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
jq -e -s --arg executable "$prompt_script" '
  .[0].harness.sandbox_write_paths == ["/tmp/reference"] and
  (.[1] | del(.id,.model_text)) ==
    {type:"hook_result",hook:"user_prompt_submit",name:"prompt-hook",
      input:"/update",executable:$executable,exit_code:11} and
  (.[1].model_text | contains("update context"))
' "$update_session" >/dev/null

# JSONL hook failures append a durable error before user acceptance.
typeset failure_session="$tmp/prompt-failure.jsonl"
sf_test_session "$failure_session"
stream=$(sf_test_turn /fail "$failure_session")
print -r -- "$stream" | jq -eRn --arg executable "$prompt_script" '
  [inputs | fromjson] as $events |
  ($events | map(.type)) == ["_hook_activity","error"] and
  ($events[0] | del(.id)) == {type:"_hook_activity",hook:"user_prompt_submit",
    name:"prompt-hook",input:"/fail",executable:$executable} and
  $events[1].user_text == ("hook script failed with status 1: " + $executable +
    ": prompt failure\n")
' >/dev/null
jq -e -s '.[-1].type == "error" and all(.[]; .type != "user")' \
  "$failure_session" >/dev/null

# Hook output respects capture limits.
typeset overflow_session="$tmp/prompt-overflow.jsonl"
sf_test_session "$overflow_session"
stream=$(sf_test_turn /overflow "$overflow_session")
print -r -- "$stream" | jq -eRn --arg executable "$prompt_script" '
  [inputs | fromjson] as $events |
  ($events | map(.type)) == ["_hook_activity","error"] and
  ($events[0] | del(.id)) == {type:"_hook_activity",hook:"user_prompt_submit",
    name:"prompt-hook",input:"/overflow",executable:$executable} and
  $events[1].user_text == ("hook script output exceeds capture limit: " + $executable)
' >/dev/null

# Cancellation stops active prompt hooks.
typeset cancel_session="$tmp/prompt-cancel.jsonl"
typeset cancel_stream="$tmp/prompt-cancel.stream"
export PROMPT_MARKER="$tmp/prompt-active"
export PROMPT_EXIT_MARKER="$tmp/prompt-exit"
SF_TEST_RUNTIME=$(jq -c '.harness.user_prompt_submit[0].render.user_before="Working…"' \
  <<<"$SF_TEST_RUNTIME")
sf_test_session "$cancel_session"
integer records=$(wc -l <"$cancel_session")
"$ROOT/bin/shellfish" run --jsonl --session "$cancel_session" \
  < <(print -r -- '{"type":"user","content":[{"type":"text","text":"/slow"}]}') \
  >"$cancel_stream" 2>/dev/null &
integer pid=$! cancel_status=0 waited=0
while (( waited++ < 50 )) && [[ ! -e $PROMPT_MARKER ]]; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'user_prompt_submit hook script did not start'
waited=0
while (( waited++ < 50 )) && ! jq -se 'any(.type == "_hook_activity" and .input == "/slow")' \
    "$cancel_stream" >/dev/null 2>&1; do
  sleep 0.1
done
(( waited <= 50 )) || fail 'user_prompt_submit display was not announced'
jq -eRn --arg executable "$prompt_script" '
  [inputs | fromjson] as $events | ($events | length) == 1 and
  $events[0].type == "_hook_activity" and
  $events[0].hook == "user_prompt_submit" and $events[0].name == "prompt-hook" and
  $events[0].input == "/slow" and $events[0].executable == $executable and
  $events[0].user_text == "Working…" and
  ($events[0].id | test("^h[0-9]+_[0-9]+$"))
' <"$cancel_stream" >/dev/null
kill -TERM "$pid"
wait "$pid" || cancel_status=$?
(( cancel_status == 143 ))
[[ ! -e $PROMPT_EXIT_MARKER ]] || fail 'cancelled user_prompt_submit hook script ran to completion'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "user" or .type == "assistant") | not) and
  ($events | map(.type)) == ["_hook_activity", "error"] and
  $events[-1].user_text == "Turn interrupted."
' <"$cancel_stream" >/dev/null
(( $(wc -l <"$cancel_session") == records + 1 )) ||
  fail 'pre-user cancellation did not append an error'
