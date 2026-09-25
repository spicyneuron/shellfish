#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-hook-contract
export XDG_STATE_HOME="$tmp/state" SF_TEST_BACKEND_DELAY=0
sf_test_frozen_profile

typeset prompt_hook="$tmp/prompt-hook" prompt_input="$tmp/prompt-input"
cat >"$prompt_hook" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 0 && $SHELLFISH_TURN_ID == <1-> &&
  -d $SHELLFISH_TURN_STATE ]] || exit 2
cat >"$PROMPT_INPUT"
case $(<"$PROMPT_INPUT") in
  accept)
    print -r -u3 -- '{"user_text":"working"}'
    print -r -u3 -- '{"user_text":"user display","model_text":"model context","finalize":true,"state":[{"name":"prompt/state","value":1}]}'
    print -r -u3 -- '{"user_text":"trailing","user_preview_lines":2}'
    print -rn -- 'trailing context'
    ;;
  shortcut)
    print -rn -- 'model context'
    print -rn -u2 -- ' user display'
    ;;
  block)
    print -rn -- 'blocked context'
    print -r -u3 -- '{"action":"block"}'
    ;;
  last)
    print -r -u3 -- '{"action":"block"}'
    print -r -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","last.jsonl"]}'
    ;;
  fail)
    print -r -u3 -- '{"action":"block"}'
    print -rn -u2 -- 'hook broke'
    exit 3
    ;;
  handoff)
    print -rn -- 'handoff context'
    print -rn -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","next.jsonl"]}'
    ;;
  update)
    print -rn -- 'update context'
    profile=$(head -n 1 "$SHELLFISH_SESSION" | jq -c \
      '.profile.sandbox_write_paths=["/tmp/reference"] | .profile') || exit 2
    jq -cn --argjson profile "$profile" \
      '{action:"session_update",profile:$profile}' >&3
    ;;
  update-invalid)
    print -rn -- 'invalid update context'
    print -rn -u3 -- '{"action":"session_update","profile":{}}'
    ;;
  drafts)
    repeat 3 print -r -u3 -- "{\"user_text\":\"${(l:30000::d:)}\"}"
    print -r -u3 -- '{"user_text":"done"}'
    ;;
  oversize)
    print -r -u3 -- '{"user_text":"kept","finalize":true}'
    print -r -u3 -- "{\"user_text\":\"${(l:70000::o:)}\"}"
    ;;
  invalid)
    print -r -u3 -- '{"user_text":"kept","model_text":"kept context","finalize":true}'
    print -r -u3 -- '{"action":"allow"}'
    print -r -u3 -- '{"user_text":"ignored","finalize":true}'
    ;;
  state)
    print -r -u3 -- '{"state":[{"name":"prompt/state","value":2}]}'
    ;;
  interrupt)
    print -r -u3 -- '{"user_text":"settled","finalize":true}'
    : >"$INTERRUPT_MARKER"
    sleep 30
    ;;
esac
ZSH
chmod +x "$prompt_hook"
export PROMPT_INPUT=$prompt_input
SF_TEST_PROFILE=$(jq -c --arg hook "$prompt_hook" '.hooks.user_prompt_submit=[$hook]' \
  <<<"$SF_TEST_PROFILE")

# A finalized section and its state settle as they arrive; user text streams as
# a draft. The trailing section keeps its own user text and takes stdout for
# the model.
typeset session="$tmp/accepted.jsonl" stream="$tmp/accepted.stream"
sf_test_session "$session"
print -r -- '{"type":"hook_result","lifecycle":"session_start","id":"7"}' >>"$session"
sf_test_run accept "$session" >"$stream" || fail 'accepted prompt hook failed'
assert_equal accept "$(<$prompt_input)" 'prompt hook did not receive exact prompt text'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type | IN("state","hook_result","user")) | .type] ==
    ["state","hook_result","hook_result","user"] and
  ($events | map(select(.type == "hook_result"))) == [{
      type:"hook_result",lifecycle:"user_prompt_submit",id:"8",
      user_text:"user display",model_text:"model context"
    }, {type:"hook_result",lifecycle:"user_prompt_submit",id:"9",
      user_text:"trailing",model_text:"trailing context",user_preview_lines:2}] and
  ($events | map(select(.type == "state"))[0]) ==
    {type:"state",name:"prompt/state",value:1} and
  ($events | map(select(.type == "_draft"))) == [
    {type:"_draft",lifecycle:"user_prompt_submit",id:"8",user_text:"working"},
    {type:"_draft",lifecycle:"user_prompt_submit",id:"9",user_text:"trailing",
     user_preview_lines:2}
  ]
' <"$stream" >/dev/null ||
  fail 'accepted prompt hook violated channel ordering'
assert_canonical_session "$session"

# By default, the user sees stdout and stderr and the model sees stdout.
session="$tmp/shortcut.jsonl"
sf_test_session "$session"
sf_test_run shortcut "$session" >"$stream" || fail 'shortcut prompt hook failed'
jq -e -s '
  map(select(.type == "hook_result")) == [{type:"hook_result",
    lifecycle:"user_prompt_submit",id:"1",
    user_text:"model context user display",model_text:"model context"}]
' "$session" >/dev/null || fail 'hook output did not settle through the shortcut'

# Lines do not add up against the capture limit; a larger line fails the hook
# after keeping what already settled.
session="$tmp/drafts.jsonl"
sf_test_session "$session"
sf_test_run drafts "$session" >"$stream" || fail 'lines counted toward the capture limit'
session="$tmp/oversize.jsonl"
sf_test_session "$session"
integer oversize_status=0
sf_test_run oversize "$session" >"$stream" 2>"$tmp/oversize.stderr" || oversize_status=$?
(( oversize_status == 1 )) || fail 'an oversized line did not fail the turn'
[[ $(<"$tmp/oversize.stderr") == *'hook output exceeds capture limit'* ]] ||
  fail 'an oversized line was not reported'
jq -e -s 'map(select(.type == "hook_result") | .user_text) == ["kept"]' "$session" \
  >/dev/null || fail 'an oversized line lost the settled result'

# A block action ends the turn before the user record.
session="$tmp/blocked.jsonl"
sf_test_session "$session"
sf_test_run block "$session" >"$stream" || fail 'blocked prompt was not handled'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "user" or .type == "assistant") | not) and
  ($events | map(select(.type == "hook_result"))[0].model_text == "blocked context")
' <"$stream" >/dev/null || fail 'blocked prompt entered provider execution'

# A handoff exposes only its allowed transient action.
session="$tmp/handoff.jsonl"
sf_test_session "$session"
sf_test_run handoff "$session" >"$stream" || fail 'handoff prompt failed'
jq -eRn '
  [inputs | fromjson] as $events |
  $events[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]} and
  ($events | any(.type == "user") | not) and
  ($events | map(select(.type == "hook_result"))[0].model_text) == "handoff context"
' <"$stream" >/dev/null || fail 'handoff control was not applied after durability'

# The last action wins.
session="$tmp/last.jsonl"
sf_test_session "$session"
sf_test_run last "$session" >"$stream" || fail 'last action prompt failed'
jq -eRn '[inputs | fromjson][-1] == {type:"_handoff",argv:["/usr/bin/printf","last.jsonl"]}' \
  <"$stream" >/dev/null || fail 'the last action did not win'

# A nonzero exit fails the turn with stderr and ignores its action.
session="$tmp/fail.jsonl"
sf_test_session "$session"
integer fail_status=0
sf_test_run fail "$session" >"$stream" 2>"$tmp/fail.stderr" || fail_status=$?
(( fail_status == 1 )) || fail 'failed hook did not fail the turn'
[[ $(<"$tmp/fail.stderr") == *'user_prompt_submit hook failed with status 3'*': hook broke'* ]] ||
  fail 'failed hook did not report stderr'
jq -e -s 'any(.[]; .type == "user" or .type == "hook_result") | not' "$session" >/dev/null ||
  fail 'failed hook submitted the prompt or settled its output'

# A session update atomically replaces only the frozen header.
session="$tmp/update.jsonl"
sf_test_session "$session"
sf_test_run update "$session" >"$stream" || fail 'session update prompt failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-1] | .type == "_session_update" and
    .profile.sandbox_write_paths == ["/tmp/reference"]) and
  ($events | any(.type == "user") | not)
' <"$stream" >/dev/null || fail 'session update did not halt before user append'
head -n 1 "$session" | jq -e \
  '.profile.sandbox_write_paths == ["/tmp/reference"]' >/dev/null ||
  fail 'session update did not replace the frozen header'

# A rejected complete profile follows the ordinary durable failure path.
session="$tmp/update-invalid.jsonl"
sf_test_session "$session"
integer update_status=0
sf_test_run update-invalid "$session" >"$stream" 2>"$tmp/update-invalid.stderr" ||
  update_status=$?
(( update_status == 1 )) || fail 'invalid session profile did not fail the turn'
jq -e -s '
  .[-2].type == "hook_result" and .[-2].model_text == "invalid update context" and
  .[-1] == {type:"error",user_text:"invalid session profile replacement"}
' "$session" >/dev/null || fail 'invalid profile did not preserve the durable failure order'
[[ $(<"$tmp/update-invalid.stderr") == *'invalid session profile replacement'* ]] ||
  fail 'invalid profile failure was not reported'

# An invalid line keeps the sections finalized before it and ignores the lines after it.
typeset invalid
session="$tmp/invalid.jsonl"
sf_test_session "$session"
integer hook_status=0
sf_test_run invalid "$session" >"$stream" 2>"$tmp/invalid.stderr" || hook_status=$?
(( hook_status == 1 )) || fail 'invalid prompt control did not fail the turn'
[[ $(<"$tmp/invalid.stderr") == *'invalid control'* ]] ||
  fail 'invalid control was not reported'
assert_canonical_session "$session"
jq -e -s '
  (map(select(.type == "hook_result") | .user_text) == ["kept"]) and
  .[-1].type == "error"
' "$session" >/dev/null || fail 'invalid control lost the settled result'

# State may ride on a line of its own.
session="$tmp/state.jsonl"
sf_test_session "$session"
sf_test_run state "$session" >"$stream" || fail 'state without text failed the turn'
jq -e -s 'map(select(.type == "state")) == [{type:"state",name:"prompt/state",value:2}]' \
  "$session" >/dev/null || fail 'state without text was not appended'
assert_canonical_session "$session"

# Interruption keeps the sections a hook already finalized.
typeset interrupt_marker="$tmp/interrupt-started"
session="$tmp/interrupt.jsonl"
sf_test_session "$session"
jq -cn '{type:"user",content:[{type:"text",text:"interrupt"}]}' |
  INTERRUPT_MARKER=$interrupt_marker "$ROOT/bin/shellfish" run --jsonl --session "$session" \
  >"$stream" &
integer pid=$! waited=0 interrupt_status=0
while (( waited++ < 100 )) && [[ ! -e $interrupt_marker ]]; do sleep 0.02; done
(( waited <= 100 )) || fail 'interrupted hook did not start'
kill -TERM "$pid" 2>/dev/null
wait "$pid" || interrupt_status=$?
(( interrupt_status == 143 )) || fail 'interrupted hook returned the wrong status'
jq -e -s 'map(select(.type == "hook_result") | .user_text) == ["settled"]' "$session" \
  >/dev/null || fail 'interruption lost a finalized section'

# Stop receives exact final assistant text and continue starts another request.
typeset stop_backend="$tmp/stop-backend/run" stop_hook="$tmp/stop-hook"
mkdir -p "${stop_backend:h}"
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
  print -r -u3 -- '{"user_text":"checking again","model_text":"continue context","action":"continue"}'
fi
ZSH
chmod +x "$stop_backend" "$stop_hook"
export STOP_INPUT=$stop_input REQUEST_COUNT=$request_count
SF_TEST_PROFILE=$(jq -c --arg backend "${stop_backend:h}" --arg hook "$stop_hook" '
  .backend.adapter=$backend |
  .hooks.user_prompt_submit=[] |
  .hooks.stop=[$hook]
' <<<"$SF_TEST_PROFILE")
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
    .lifecycle == "stop" and
    .model_text == "continue context" and .user_text == "checking again")
' <"$stream" >/dev/null || fail 'stop continuation produced the wrong durable order'
assert_canonical_session "$session"

# Stop continuation cannot exceed the frozen provider request limit.
rm -f "$request_count"
SF_TEST_PROFILE=$(jq -c '.max_requests_per_turn=1' <<<"$SF_TEST_PROFILE")
session="$tmp/request-limit.jsonl"
sf_test_session "$session"
integer limit_status=0
sf_test_run stop "$session" >"$stream" || limit_status=$?
(( limit_status == 1 )) || fail 'provider request limit did not fail the turn'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-2] | .type == "hook_result" and .lifecycle == "stop" and
    .model_text == "continue context") and
  $events[-1] == {type:"error",user_text:"provider request limit reached: 1"}
' <"$stream" >/dev/null || fail 'request limit lost stop feedback or its error'
assert_canonical_session "$session"

# A continuation without model feedback fails before another provider request.
cat >"$stop_hook" <<'ZSH'
#!/usr/bin/env zsh
print -r -u3 -- '{"user_text":"checking again","action":"continue"}'
ZSH
chmod +x "$stop_hook"
rm -f "$request_count"
SF_TEST_PROFILE=$(jq -c '.max_requests_per_turn=8' <<<"$SF_TEST_PROFILE")
session="$tmp/stop-no-feedback.jsonl"
sf_test_session "$session"
integer no_feedback_status=0
sf_test_run stop "$session" >"$stream" || no_feedback_status=$?
(( no_feedback_status == 1 )) || fail 'stop continuation without feedback succeeded'
assert_equal 1 "$(<$request_count)" 'stop continuation without feedback requested again'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-2] | .type == "hook_result" and .user_text == "checking again") and
  $events[-1] == {type:"error",user_text:"stop hook continued without model feedback"}
' <"$stream" >/dev/null || fail 'stop continuation without feedback was not rejected'
assert_canonical_session "$session"

# Each hook receives the original input and settles before the next starts.
typeset delegate="$tmp/delegate"
cat >"$delegate" <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
[[ $# == 0 && $input == ordered ]] || exit 2
if [[ ${0:t} != one ]]; then
  jq -e -s --arg prev "$PREVIOUS" \
    'any(.[]; .type == "hook_result" and .user_text == $prev)' \
    "$SHELLFISH_SESSION" >/dev/null || exit 3
fi
print -r -u3 -- "{\"user_text\":\"${0:t}: $input\",\"finalize\":true}"
ZSH
chmod +x "$delegate"
ln -s delegate "$tmp/one"
ln -s delegate "$tmp/two"
ln -s delegate "$tmp/three"
export PREVIOUS='one: ordered'
SF_TEST_PROFILE=$(jq -c --arg dir "$tmp" '
  .hooks.stop=[] | .hooks.user_prompt_submit=[$dir + "/one", $dir + "/two", $dir + "/three"]
' <<<"$SF_TEST_PROFILE")
session="$tmp/delegate.jsonl"
sf_test_session "$session"
sf_test_run ordered "$session" >"$stream" || fail 'ordered hooks failed'
jq -e -s '
  map(select(.type == "hook_result") | .user_text) ==
    ["one: ordered", "two: ordered", "three: ordered"]
' "$session" >/dev/null || fail 'hook list lost stdin or reordered fd 3'

# An action stops the list, and a later failure keeps earlier settled output.
rm "$tmp/two"
cat >"$tmp/two" <<'ZSH'
#!/usr/bin/env zsh
print -r -u3 -- '{"user_text":"terminal","finalize":true,"action":"block"}'
ZSH
chmod +x "$tmp/two"
session="$tmp/terminal.jsonl"
sf_test_session "$session"
sf_test_run ordered "$session" >"$stream" || fail 'terminal hook failed'
jq -e -s '
  map(select(.type == "hook_result") | .user_text) == ["one: ordered", "terminal"] and
  (any(.[]; .type == "user") | not)
' "$session" >/dev/null || fail 'terminal action did not stop later hooks'

cat >"$tmp/two" <<'ZSH'
#!/usr/bin/env zsh
print -r -u3 -- '{"user_text":"failed section","finalize":true}'
exit 7
ZSH
chmod +x "$tmp/two"
session="$tmp/later-error.jsonl"
sf_test_session "$session"
integer later_status=0
sf_test_run ordered "$session" >"$stream" 2>"$tmp/later-error.stderr" || later_status=$?
(( later_status == 1 )) || fail 'later hook failure did not fail the turn'
jq -e -s '
  map(select(.type == "hook_result") | .user_text) == ["one: ordered", "failed section"] and
  .[-1].type == "error"
' "$session" >/dev/null || fail 'later hook failure lost settled output'

# The bundled sandbox hook compares stored grants with shell-resolved input.
typeset sandbox_hook="$ROOT/share/profiles/default/hooks/sandbox"
typeset sandbox_session="$tmp/sandbox.jsonl" sandbox_control="$tmp/sandbox-control.json"
typeset sandbox_project="$tmp/project" sandbox_home="$tmp/home" sandbox_output="$tmp/sandbox-output"
mkdir -p "$sandbox_project/dir" "$sandbox_home/share"
jq -c --arg cwd "${sandbox_project:A}" '
  .cwd=$cwd | .profile.sandbox=true |
  .profile.sandbox_write_paths=[$cwd + "/dir","~/share"]
' "$SF_TEST_SESSIONS/header-only.jsonl" >"$sandbox_session"
(
  builtin cd -- "$sandbox_project"
  export HOME="$sandbox_home"
  sandbox_call() {
    print -rn -- "$1" | SHELLFISH_SESSION="$sandbox_session" \
      zsh -f "$sandbox_hook" 3>"$sandbox_control" >"$sandbox_output" 2>&1
  }
  sandbox_action() {
    sandbox_call "$1" || fail "sandbox hook failed: $1"
    jq -rs 'last.action' "$sandbox_control"
  }
  [[ $(sandbox_action '/sandbox +w dir') == block ]] ||
    fail 'absolute grant was duplicated'
  [[ $(sandbox_action '/sandbox +w ~/share') == block ]] ||
    fail 'home-relative grant was duplicated'
  [[ $(sandbox_action "/sandbox -w ${sandbox_project:A}/dir") == session_update ]] ||
    fail 'absolute grant could not be removed'
  jq -es 'last.profile.sandbox_write_paths == ["~/share"]' \
    "$sandbox_control" >/dev/null || fail 'sandbox removed the wrong grant'
  [[ $(sandbox_action '/sandbox -w ~/share') == session_update ]] ||
    fail 'home-relative grant could not be removed'
  jq -es --arg dir "${sandbox_project:A}/dir" 'last.profile.sandbox_write_paths == [$dir]' \
    "$sandbox_control" >/dev/null || fail 'sandbox removed the wrong home grant'
)

print -r -- ok
