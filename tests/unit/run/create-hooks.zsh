#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp run-create-hook-contract
export XDG_STATE_HOME="$tmp/state"
sf_test_config
typeset entry="$ROOT/bin/shellfish" hook="$tmp/start"
typeset input="$tmp/input" session="$tmp/session.jsonl" stream="$tmp/stream"

cat >"$hook" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 0 && $SHELLFISH_MODEL == test && -z ${SHELLFISH_TURN_ID-} &&
  -z ${SHELLFISH_TURN_STATE-} ]] || exit 2
cat >"$START_INPUT"
print -r -u3 -- '{"user_text":"Starting up"}'
print -r -u3 -- '{"user_text":"startup display","model_text":"startup model","finalize":true,"state":[{"name":"startup/state","value":true}]}'
ZSH
chmod +x "$hook"
sf_test_profile default "{
  \"backend\":{\"adapter\":\"$ROOT/tests/fixtures/backend\"},
  \"request\":{\"model\":\"test\"},
  \"tools\":[],\"sandbox\":false,\"hooks\":{\"session_start\":[\"$hook\"]},
  \"max_requests_per_turn\":2,\"max_tool_calls_per_request\":2,
  \"max_capture_bytes\":1024
}"
export START_INPUT=$input

zsh -f "$entry" run --jsonl --session-create --session-out "$session" \
  >"$stream" || fail 'session_start hook failed'
[[ ! -s $input ]] || fail 'session_start hook received nonempty stdin'
jq -eRn --arg session "$session" '
  [inputs | fromjson] as $events |
  ($events[2] | .type == "_draft" and .lifecycle == "session_start" and
    .user_text == "Starting up") and
  [$events[] | .type] ==
    ["_session_load","session","_draft","state","hook_result"] and
  ($events[0] == {type:"_session_load",path:$session}) and
  ($events[-1] | del(.id)) == {
    type:"hook_result",lifecycle:"session_start",
    user_text:"startup display",model_text:"startup model"
  }
' <"$stream" >/dev/null || fail 'session_start channels or ordering were wrong'
jq -e -s '
  .[-2] == {type:"state",name:"startup/state",value:true} and
  (.[-1] | .type == "hook_result" and .lifecycle == "session_start")
' "$session" >/dev/null || fail 'startup records were not durable'
assert_canonical_session "$session"

# A successful hook that releases its user text without output clears its draft.
cat >"$hook" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -u3 -- '{"user_text":"Starting up"}'
print -r -u3 -- '{"user_text":"","finalize":true}'
ZSH
chmod +x "$hook"
session="$tmp/silent.jsonl"
zsh -f "$entry" run --jsonl --session-create --session-out "$session" \
  >"$stream" || fail 'silent session_start hook failed'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[].type] == ["_session_load","session","_draft","_draft"] and
  ($events[3] | del(.id)) ==
    {type:"_draft",lifecycle:"session_start",user_text:""}
' <"$stream" >/dev/null ||
  fail 'silent session_start activity did not clear'
assert_canonical_session "$session"

# An action or a nonzero exit fails session_start and preserves the published
# session with the results already settled.
typeset -A unsupported_cases=(
  action "print -r -u3 -- '{\"action\":\"block\"}'"
  status 'exit 3'
)
typeset -A unsupported_errors=(
  action 'invalid control'
  status 'failed with status 3*unsupported display'
)
for unsupported in action status; do
  cat >"$hook" <<ZSH
#!/usr/bin/env zsh
cat >/dev/null
print -r -u3 -- '{"model_text":"unsupported model","finalize":true}'
print -rn -u2 -- 'unsupported display'
$unsupported_cases[$unsupported]
ZSH
  chmod +x "$hook"
  session="$tmp/unsupported-$unsupported.jsonl"
  integer create_status=0
  zsh -f "$entry" run --jsonl --session-create --session-out "$session" \
    >"$stream" 2>"$tmp/unsupported.stderr" || create_status=$?
  (( create_status == 1 )) || fail "session_start accepted $unsupported"
  [[ -f $session ]] || fail 'failed session_start removed the transcript it wrote'
  jq -eRn --arg session "$session" '
    [inputs | fromjson] as $events |
    [$events[].type] == ["_session_load","session","hook_result"] and
    $events[0] == {type:"_session_load",path:$session}
  ' <"$stream" >/dev/null || fail 'failed creation lost its ordered durable stream'
  jq -e -s '.[-1].type == "hook_result"' \
    "$session" >/dev/null || fail 'failed startup result was not durable'
  [[ $(<"$tmp/unsupported.stderr") == *${~unsupported_errors[$unsupported]}* ]] ||
    fail "session_start $unsupported lost its diagnostic"
done

print -r -- ok
