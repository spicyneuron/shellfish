#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-hook-contract
export XDG_STATE_HOME="$tmp/state" SF_TEST_BACKEND_DELAY=0
sf_test_runtime

typeset prompt_hook="$tmp/prompt-hook" second_hook="$tmp/second-hook"
typeset prompt_input="$tmp/prompt-input" second_marker="$tmp/second-ran"
cat >"$prompt_hook" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 0 && $SHELLFISH_TURN_ID == <1-> &&
  -d $SHELLFISH_TURN_STATE ]] || exit 2
cat >"$PROMPT_INPUT"
case $(<"$PROMPT_INPUT") in
  accept)
    print -rn -- 'model context'
    print -rn -u2 -- 'user display'
    print -rn -u3 -- '{"state":[{"name":"prompt/state","value":1}]}'
    ;;
  block)
    print -rn -- 'blocked context'
    print -rn -u2 -- 'blocked display'
    exit 10
    ;;
  handoff)
    print -rn -- 'handoff context'
    print -rn -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","next.jsonl"]}'
    exit 11
    ;;
  update)
    print -rn -- 'update context'
    runtime=$(head -n 1 "$SHELLFISH_SESSION" | jq -c \
      '.runtime.harness.sandbox_write_paths=["/tmp/reference"] | .runtime') || exit 2
    jq -cn --argjson runtime "$runtime" \
      '{action:"session_update",runtime:$runtime}' >&3
    exit 11
    ;;
  update-invalid)
    print -rn -- 'invalid update context'
    print -rn -u3 -- '{"action":"session_update","runtime":{}}'
    exit 11
    ;;
  invalid)
    print -rn -- 'failed context'
    print -rn -u2 -- 'failed display'
    print -rn -u3 -- '{"action":"allow"}'
    ;;
esac
ZSH
cat >"$second_hook" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
: >"$SECOND_MARKER"
ZSH
chmod +x "$prompt_hook" "$second_hook"
export PROMPT_INPUT=$prompt_input SECOND_MARKER=$second_marker
SF_TEST_RUNTIME=$(jq -c --arg first "$prompt_hook" --arg second "$second_hook" '
  .harness.user_prompt_submit=[
    {command:$first,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}},
    {command:$second,render:{initial_user_text:"second · working",user_text:"${output.stderr}",model_text:"${output.stdout}"}}
  ]
' <<<"$SF_TEST_RUNTIME")

# Status 0 persists state and attributed output before the accepted user record.
typeset session="$tmp/accepted.jsonl" stream="$tmp/accepted.stream"
sf_test_session "$session"
print -r -- '{"type":"hook_result","lifecycle":"session_start","id":"7","name":"prior","input":"","exit_code":0}' \
  >>"$session"
sf_test_run accept "$session" >"$stream" || fail 'accepted prompt hook failed'
assert_equal accept "$(<$prompt_input)" 'prompt hook did not receive exact prompt text'
jq -eRn --arg second "$second_hook" '
  [inputs | fromjson] as $events |
  [$events[] | select(.type | IN("state","hook_result","user")) | .type] ==
    ["state","hook_result","user"] and
  ($events | map(select(.type == "hook_result"))[0]) == {
      type:"hook_result",lifecycle:"user_prompt_submit",id:"8",name:"prompt-hook",
      input:"accept",exit_code:0,
      user_text:"user display",model_text:"model context"
    } and
  ($events | map(select(.type == "state"))[0]) ==
    {type:"state",name:"prompt/state",value:1} and
  ($events | map(select(.type == "_hook_activity" and .name == "second-hook"))) == [
    {type:"_hook_activity",hook:"user_prompt_submit",id:"9",name:"second-hook",
     executable:$second,input:"accept",user_text:"second · working"},
    {type:"_hook_activity",hook:"user_prompt_submit",id:"9",name:"second-hook",
     executable:$second,input:"accept"}
  ]
' <"$stream" >/dev/null ||
  fail 'accepted prompt hook violated channel ordering'
assert_canonical_session "$session"

# Status 10 selects block but continues the chain; a later zero cannot undo it.
rm -f "$second_marker"
session="$tmp/blocked.jsonl"
sf_test_session "$session"
sf_test_run block "$session" >"$stream" || fail 'blocked prompt was not handled'
[[ -e $second_marker ]] || fail 'status 10 did not continue the hook chain'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "user" or .type == "assistant") | not) and
  ($events | map(select(.type == "hook_result"))[0] |
    .exit_code == 10 and .model_text == "blocked context" and
    .user_text == "blocked display")
' <"$stream" >/dev/null || fail 'blocked prompt entered provider execution'

# Status 11 halts the chain and exposes only its allowed transient action.
rm -f "$second_marker"
session="$tmp/handoff.jsonl"
sf_test_session "$session"
sf_test_run handoff "$session" >"$stream" || fail 'handoff prompt failed'
[[ ! -e $second_marker ]] || fail 'status 11 did not halt the hook chain'
jq -eRn '
  [inputs | fromjson] as $events |
  $events[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]} and
  ($events | any(.type == "user") | not) and
  ($events | map(select(.type == "hook_result"))[0].model_text) == "handoff context"
' <"$stream" >/dev/null || fail 'handoff control was not applied after durability'

# A halted session update atomically replaces only the frozen header.
session="$tmp/update.jsonl"
sf_test_session "$session"
sf_test_run update "$session" >"$stream" || fail 'session update prompt failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-1] | .type == "_session_update" and
    .runtime.harness.sandbox_write_paths == ["/tmp/reference"]) and
  ($events | any(.type == "user") | not)
' <"$stream" >/dev/null || fail 'session update did not halt before user append'
head -n 1 "$session" | jq -e \
  '.runtime.harness.sandbox_write_paths == ["/tmp/reference"]' >/dev/null ||
  fail 'session update did not replace the frozen header'

# A rejected complete runtime follows the ordinary durable failure path.
session="$tmp/update-invalid.jsonl"
sf_test_session "$session"
integer update_status=0
sf_test_run update-invalid "$session" >"$stream" 2>"$tmp/update-invalid.stderr" ||
  update_status=$?
(( update_status == 1 )) || fail 'invalid session runtime did not fail the turn'
jq -e -s '
  .[-2].type == "hook_result" and .[-2].model_text == "invalid update context" and
  .[-1] == {type:"error",user_text:"invalid session runtime replacement"}
' "$session" >/dev/null || fail 'invalid runtime did not preserve the durable failure order'
[[ $(<"$tmp/update-invalid.stderr") == *'invalid session runtime replacement'* ]] ||
  fail 'invalid runtime failure was not reported'

# Invalid lifecycle control keeps completed output before the durable error.
session="$tmp/invalid.jsonl"
sf_test_session "$session"
integer hook_status=0
sf_test_run invalid "$session" >"$stream" 2>"$tmp/invalid.stderr" || hook_status=$?
(( hook_status == 1 )) || fail 'invalid prompt control did not fail the turn'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-2] | .type == "hook_result" and .exit_code == 0 and
    .model_text == "failed context" and .user_text == "failed display") and
  ($events[-1] | .type == "error" and (.user_text | contains("invalid control")))
' <"$stream" >/dev/null || fail 'invalid control lost the completed hook result'
assert_canonical_session "$session"

# Stop receives exact final assistant text and status 10 starts another request.
typeset stop_backend="$tmp/stop-backend" stop_hook="$tmp/stop-hook"
typeset stop_input="$tmp/stop-input" request_count="$tmp/request-count"
cat >"$stop_backend" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
integer count=0
[[ ! -s $REQUEST_COUNT ]] || count=$(<$REQUEST_COUNT)
(( count += 1 ))
print -r -- $count >"$REQUEST_COUNT"
print -r -- "{\"type\":\"_assistant_message_delta\",\"index\":0,\"text\":\"answer $count\"}"
print -r -- '{"type":"_turn_usage","input_tokens":1,"output_tokens":1}'
print -r -- '{"type":"_assistant_end","stop":"end"}'
ZSH
cat >"$stop_hook" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 1 && $1 == <1-> ]] || exit 2
cat >"$STOP_INPUT"
if [[ $1 == 1 ]]; then
  print -rn -- 'continue context'
  print -rn -u2 -- 'checking again'
  exit 10
fi
ZSH
chmod +x "$stop_backend" "$stop_hook"
export STOP_INPUT=$stop_input REQUEST_COUNT=$request_count
SF_TEST_RUNTIME=$(jq -c --arg backend "$stop_backend" --arg hook "$stop_hook" '
  .backend.command=$backend |
  .harness.user_prompt_submit=[] |
  .harness.stop=[{command:$hook,render:{initial_user_text:"",user_text:"${output.stderr}",model_text:"${output.stdout}"}}]
' <<<"$SF_TEST_RUNTIME")
session="$tmp/stop.jsonl"
sf_test_session "$session"
sf_test_run stop "$session" >"$stream" || fail 'stop continuation failed'
assert_equal 'answer 2' "$(<$stop_input)" 'stop hook did not receive final assistant text'
assert_equal 2 "$(<$request_count)" 'stop hook did not continue provider requests'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "assistant") | .content[0].text)) ==
    ["answer 1","answer 2"] and
  ($events | map(select(.type == "hook_result")) | length) == 1 and
  ($events | map(select(.type == "hook_result"))[0] |
    .lifecycle == "stop" and .exit_code == 10 and
    .model_text == "continue context" and .user_text == "checking again")
' <"$stream" >/dev/null || fail 'stop continuation produced the wrong durable order'
assert_canonical_session "$session"

# Stop continuation cannot exceed the frozen provider request limit.
rm -f "$request_count"
SF_TEST_RUNTIME=$(jq -c '.harness.max_requests_per_turn=1' <<<"$SF_TEST_RUNTIME")
session="$tmp/request-limit.jsonl"
sf_test_session "$session"
integer limit_status=0
sf_test_run stop "$session" >"$stream" || limit_status=$?
(( limit_status == 1 )) || fail 'provider request limit did not fail the turn'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-2] | .type == "hook_result" and .lifecycle == "stop" and
    .exit_code == 10 and .model_text == "continue context") and
  $events[-1] == {type:"error",user_text:"provider request limit reached: 1"}
' <"$stream" >/dev/null || fail 'request limit lost stop feedback or its error'
assert_canonical_session "$session"

# The bundled sandbox hook compares portable grants with shell-resolved input.
typeset sandbox_hook="$ROOT/share/profiles/default/hooks/user_prompt_submit/sandbox/run"
typeset sandbox_session="$tmp/sandbox.jsonl" sandbox_control="$tmp/sandbox-control.json"
typeset sandbox_project="$tmp/project" sandbox_home="$tmp/home" sandbox_output="$tmp/sandbox-output"
mkdir -p "$sandbox_project/dir" "$sandbox_home/share"
jq -c --arg cwd "${sandbox_project:A}" '
  .cwd=$cwd | .runtime.harness.sandbox=true |
  .runtime.harness.sandbox_write_paths=["./dir","~/share"]
' "$SF_TEST_SESSIONS/header-only.jsonl" >"$sandbox_session"
(
  builtin cd -- "$sandbox_project"
  export HOME="$sandbox_home"
  sandbox_call() {
    print -rn -- "$1" | SHELLFISH_SESSION="$sandbox_session" \
      zsh -f "$sandbox_hook" 3>"$sandbox_control" >"$sandbox_output" 2>&1
  }
  integer sandbox_status=0
  sandbox_call '/sandbox +w dir' || sandbox_status=$?
  (( sandbox_status == 10 )) || fail 'project-relative grant was duplicated'
  sandbox_status=0
  sandbox_call '/sandbox +w ~/share' || sandbox_status=$?
  (( sandbox_status == 10 )) || fail 'home-relative grant was duplicated'
  sandbox_status=0
  sandbox_call "/sandbox -w ${sandbox_project:A}/dir" || sandbox_status=$?
  (( sandbox_status == 11 )) || fail 'project-relative grant could not be removed'
  jq -e '.runtime.harness.sandbox_write_paths == ["~/share"]' \
    "$sandbox_control" >/dev/null || fail 'sandbox removed the wrong grant'
  sandbox_status=0
  sandbox_call '/sandbox -w ~/share' || sandbox_status=$?
  (( sandbox_status == 11 )) || fail 'home-relative grant could not be removed'
  jq -e '.runtime.harness.sandbox_write_paths == ["./dir"]' \
    "$sandbox_control" >/dev/null || fail 'sandbox removed the wrong home grant'
)

print -r -- ok
