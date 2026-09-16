#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp create-hook-contract
export XDG_STATE_HOME="$tmp/state"
typeset entry="$ROOT/bin/shellfish" hook="$tmp/start" config="$tmp/config.jsonc"
typeset input="$tmp/input" session="$tmp/session.jsonl" stream="$tmp/stream"
mkdir "$hook"
print -r -- '{"environment":["START_INPUT"],"initial_user_text":"Starting up"}' \
  >"$hook/manifest.json"
cat >"$hook/run" <<'ZSH'
#!/usr/bin/env zsh
[[ $1 == session_start && $SHELLFISH_MODEL == test && -z ${SHELLFISH_TURN_ID-} &&
  -z ${SHELLFISH_TURN_STATE-} ]] || exit 2
cat >"$START_INPUT"
print -rn -- 'startup model'
print -rn -u2 -- 'startup display'
print -rn -u3 -- '{"state":[{"name":"startup/state","value":true}]}'
ZSH
chmod +x "$hook/run"
cat >"$config" <<EOF
{
  "default_profile":"test",
  "backends":{"test":{"adapter":"$ROOT/tests/fixtures/backend"}},
  "harnesses":{"test":{
    "tools":[],"sandbox":false,"session_start":["$hook"],
    "max_requests_per_turn":2,"max_tool_calls_per_request":2,
    "max_capture_bytes":1024
  }},
  "profiles":{"test":{"backend":"test","harness":"test",
    "request":{"model":"test"}}}
}
EOF
export START_INPUT=$input

zsh -f "$entry" create --jsonl --config "$config" --session-out "$session" \
  >"$stream" || fail 'session_start hook failed'
[[ ! -s $input ]] || fail 'session_start hook received nonempty stdin'
jq -eRn --arg session "$session" --arg executable "${hook:A}/run" '
  [inputs | fromjson] as $events |
  ($events | any(.type == "_hook_activity" and .hook == "session_start" and
    .user_text == "Starting up")) and
  [$events[] | .type] ==
    ["_hook_activity","_session_load","session","state","hook_result"] and
  ($events[1] == {type:"_session_load",path:$session}) and
  ($events[-1] | del(.id)) == {
    type:"hook_result",lifecycle:"session_start",name:"start",input:"",
    executable:$executable,exit_code:0,user_text:"startup display",
    model_text:"startup model"
  }
' <"$stream" >/dev/null || fail 'session_start channels or ordering were wrong'
jq -e -s '
  .[-2] == {type:"state",name:"startup/state",value:true} and
  (.[-1] | .type == "hook_result" and .lifecycle == "session_start")
' "$session" >/dev/null || fail 'startup records were not durable'
assert_canonical_session "$session"

# Skip and halt statuses are unsupported for session_start and preserve a
# completed failed hook result before creation is removed.
for unsupported in 10 11; do
  cat >"$hook/run" <<ZSH
#!/usr/bin/env zsh
cat >/dev/null
print -rn -- 'unsupported model'
print -rn -u2 -- 'unsupported display'
exit $unsupported
ZSH
  chmod +x "$hook/run"
  session="$tmp/unsupported-$unsupported.jsonl"
  integer create_status=0
  zsh -f "$entry" create --jsonl --config "$config" --session-out "$session" \
    >"$stream" 2>"$tmp/unsupported.stderr" || create_status=$?
  (( create_status == 1 )) || fail "session_start accepted status $unsupported"
  [[ ! -e $session ]] || fail 'failed session_start left an authoritative session'
  jq -eRn '
    [inputs | fromjson] as $events |
    ($events | all(.type == "_hook_activity"))
  ' <"$stream" >/dev/null || fail 'failed creation streamed durable records'
  [[ $(<"$tmp/unsupported.stderr") == *'unsupported status'*'unsupported display'* ]] ||
    fail 'unsupported startup status lost its diagnostic'
done

print -r -- ok
