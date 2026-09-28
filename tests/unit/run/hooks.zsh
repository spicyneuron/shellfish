#!/usr/bin/env zsh
source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp run-hook-contract
export XDG_STATE_HOME="$tmp/state" SF_TEST_BACKEND_DELAY=0
sf_test_frozen_profile
typeset hook="$tmp/prompt" session stream="$tmp/stream"
sf_test_hook "$hook" '{"user_text_done":"${output.stdout}","model_text":"${output.stdout}"}' <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 0 && $SHELLFISH_TURN_ID == <1-> && -d $SHELLFISH_TURN_STATE ]] || exit 2
input=$(cat)
case $input in
  handoff) print -r -u3 -- '{"action":"block"}'
    print -r -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","next.jsonl"]}'
    print -rn -- 'handoff context' ;;
  update|bad-update)
    profile=$(head -n 1 "$SHELLFISH_SESSION" | jq -c '.profile.sandbox_write_paths=["/tmp/reference"] | .profile') || exit 2
    [[ $input != bad-update ]] || profile='{}'
    jq -cn --argjson profile "$profile" '{action:"session_update",profile:$profile}' >&3
    print -rn -- 'update context' ;;
  fail) print -r -u3 -- '{"state":[{"name":"prompt/failed","value":true}],"action":"block"}'; print -rn -u2 -- 'hook broke'; exit 3 ;;
  invalid) print -r -u3 -- '{"action":"deny"}' ;;
  state) print -r -u3 -- '{"state":[{"name":"prompt/state","value":2}]}' ;;
  interrupt) print -r -u3 -- '{"state":[{"name":"prompt/started","value":true}],"user_text":"Working"}'
    : >"$INTERRUPT_MARKER"; sleep 30 ;;
esac
ZSH
SF_TEST_PROFILE=$(jq -c --arg hook "$hook" '.hooks.user_prompt_submit=[$hook]' <<<"$SF_TEST_PROFILE")
new_session() { session="$tmp/$1.jsonl"; sf_test_session "$session"; }
new_session handoff; sf_test_run handoff "$session" >"$stream" || fail 'handoff failed'
jq -eRn '[inputs | fromjson] as $e | $e[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]} and
  $e[-2].model_text == "handoff context" and ([ $e[] | select(.type == "user") ] | length) == 0' \
  <"$stream" >/dev/null || fail 'last action or handoff durability failed'
new_session update; sf_test_run update "$session" >"$stream" || fail 'session update failed'
jq -e -s 'map(.type) == ["session","hook_result"] and .[0].profile.sandbox_write_paths == ["/tmp/reference"]' "$session" >/dev/null &&
  jq -eRn '[inputs | fromjson][-1].type == "_session_update"' <"$stream" >/dev/null || fail 'session update did not replace header'
new_session bad-update; sf_test_run bad-update "$session" >"$stream" 2>"$tmp/update.err" && fail 'invalid update succeeded'
jq -e -s '.[-2].model_text == "update context" and
  .[-1] == {type:"error",user_text:"invalid session profile replacement"}' "$session" >/dev/null ||
  fail 'invalid update lost settled result'
new_session fail; sf_test_run fail "$session" >"$stream" 2>"$tmp/fail.err" && fail 'nonzero hook succeeded'
[[ $(<"$tmp/fail.err") == *'failed with status 3'*'hook broke'* ]] || fail 'nonzero diagnostic lost'
jq -e -s 'map(.type) == ["session","state","error"]' "$session" >/dev/null ||
  fail 'failed hook lost state or applied its action'
new_session invalid; sf_test_run invalid "$session" >"$stream" 2>"$tmp/invalid.err" && fail 'invalid action succeeded'
[[ $(<"$tmp/invalid.err") == *'invalid control'* ]] || fail 'invalid action lost its diagnostic'
jq -e -s 'map(.type) == ["session","error"]' "$session" >/dev/null || fail 'invalid action settled'
new_session state; sf_test_run state "$session" >"$stream" || fail 'state-only hook failed'
jq -e -s '.[1] == {type:"state",name:"prompt/state",value:2} and
  (map(.type) | index("hook_result") == null)' "$session" >/dev/null || fail 'state-only update was not durable'
# Interrupted work retains state, not an unfinished result.
typeset marker="$tmp/started"
new_session interrupt
jq -cn '{type:"user",content:[{type:"text",text:"interrupt"}]}' |
  INTERRUPT_MARKER=$marker "$ROOT/bin/shellfish" run --jsonl --session "$session" >"$stream" &
integer pid=$! waited=0 interrupted=0
while (( waited++ < 100 )) && [[ ! -e $marker ]]; do sleep 0.02; done
[[ -e $marker ]] || fail 'interrupt hook did not start'
kill -TERM "$pid"; wait "$pid" || interrupted=$?
(( interrupted == 143 )) || fail 'interrupted hook returned wrong status'
jq -e -s '.[1] == {type:"state",name:"prompt/started",value:true} and
  (map(.type) | index("hook_result") == null)' "$session" >/dev/null ||
  fail 'interruption lost state or settled unfinished output'
# Stop receives final assistant text and can continue only with model feedback.
typeset backend="$tmp/backend/run" stop="$tmp/stop" count="$tmp/count" stop_input="$tmp/stop-input"
mkdir -p "${backend:h}"
cat >"$backend" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
integer n=0
[[ ! -s $REQUEST_COUNT ]] || n=$(<$REQUEST_COUNT)
(( n++ ))
print -r -- $n >"$REQUEST_COUNT"
print -r -- "{\"type\":\"_assistant_message_delta\",\"index\":0,\"text\":\"answer $n\"}"
print -r -- '{"type":"_turn_usage","input_tokens":1,"output_tokens":1}'
print -r -- '{"type":"_assistant_end","stop":"end"}'
ZSH
sf_test_hook "$stop" '{"user_text_done":"${output.stdout}","model_text":"${output.stdout}"}' <<'ZSH'
#!/usr/bin/env zsh
cat >"$STOP_INPUT"
if [[ $1 == 1 ]]; then
  [[ ! -e $STOP_SILENT ]] || print -r -u3 -- '{"model_text":""}'
  print -r -u3 -- '{"action":"continue"}'
  print -rn -- 'checking again'
fi
ZSH
chmod +x "$backend"
export REQUEST_COUNT=$count STOP_INPUT=$stop_input STOP_SILENT="$tmp/silent"
SF_TEST_PROFILE=$(jq -c --arg backend "${backend:h}" --arg hook "$stop" '
  .backend.adapter=$backend | .hooks.user_prompt_submit=[] | .hooks.stop=[$hook]' <<<"$SF_TEST_PROFILE")
new_session stop; sf_test_run stop "$session" >"$stream" || fail 'stop continuation failed'
assert_equal 'answer 2' "$(<$stop_input)" 'stop input was not final assistant text'
assert_equal 2 "$(<$count)" 'stop did not continue provider'
jq -e -s 'map(select(.type == "hook_result") | .model_text) == ["checking again"]' "$session" \
  >/dev/null || fail 'stop feedback did not settle'
SF_TEST_PROFILE=$(jq -c '.max_requests_per_turn=1' <<<"$SF_TEST_PROFILE")
new_session limit; sf_test_run stop "$session" >"$stream" 2>"$tmp/limit.err" && fail 'request limit succeeded'
jq -e -s '.[-2].model_text == "checking again" and
  .[-1] == {type:"error",user_text:"provider request limit reached: 1"}' "$session" >/dev/null ||
  fail 'request limit lost feedback'
: >"$STOP_SILENT"
rm -f "$count"
SF_TEST_PROFILE=$(jq -c '.max_requests_per_turn=8' <<<"$SF_TEST_PROFILE")
new_session no-feedback; sf_test_run stop "$session" >"$stream" 2>"$tmp/feedback.err" && fail 'missing feedback succeeded'
assert_equal 1 "$(<$count)" 'stop without feedback requested again'
jq -e -s '.[-2].user_text == "checking again" and (.[-2] | has("model_text") | not) and
  .[-1] == {type:"error",user_text:"stop hook continued without model feedback"}' "$session" \
  >/dev/null || fail 'missing stop feedback was accepted'
# Ordered hooks see original input and preceding results. An action stops the list.
typeset hooks="$tmp/hooks" name
sf_test_hook "$hooks/one" '{"user_text_done":"${output.stdout}"}' <<'ZSH'
#!/usr/bin/env zsh
name=${0:h:t}; input=$(cat)
[[ $input == ordered ]] || exit 2
if [[ $name != one ]]; then
  [[ $name == two ]] && prev='one: ordered' || prev='two: ordered'
  jq -e -s --arg prev "$prev" 'any(.[]; .type == "hook_result" and .user_text == $prev)' \
    "$SHELLFISH_SESSION" >/dev/null || exit 3
fi
[[ $name != two || ! -e $FAIL_TWO ]] || exit 7
[[ $name != two || ! -e $BLOCK_TWO ]] || print -r -u3 -- '{"action":"block"}'
print -rn -- "$name: $input"
ZSH
for name in two three; do
  sf_test_hook "$hooks/$name" '{"user_text_done":"${output.stdout}"}' <"$hooks/one/run"
done
export BLOCK_TWO="$tmp/block-two" FAIL_TWO="$tmp/fail-two"
SF_TEST_PROFILE=$(jq -c --arg dir "$hooks" --arg adapter "${SF_TEST_BACKEND:h}" '
  .backend.adapter=$adapter | .hooks.stop=[] |
  .hooks.user_prompt_submit=[$dir + "/one",$dir + "/two",$dir + "/three"]' <<<"$SF_TEST_PROFILE")
new_session ordered; sf_test_run ordered "$session" >"$stream" || fail 'ordered hooks failed'
jq -e -s 'map(select(.type == "hook_result") | .user_text) ==
  ["one: ordered","two: ordered","three: ordered"]' "$session" >/dev/null ||
  fail 'hook order or input was wrong'
: >"$BLOCK_TWO"; new_session blocked; sf_test_run ordered "$session" >"$stream" || fail 'block failed'
jq -e -s 'map(select(.type == "hook_result") | .user_text) == ["one: ordered","two: ordered"] and
  (map(.type) | index("user") == null)' "$session" >/dev/null || fail 'block did not stop list'
rm "$BLOCK_TWO"; : >"$FAIL_TWO"; new_session later-error
sf_test_run ordered "$session" >"$stream" 2>"$tmp/later.err" && fail 'later hook succeeded'
jq -e -s 'map(select(.type == "hook_result") | .user_text) == ["one: ordered"] and
  .[-1].type == "error"' "$session" >/dev/null || fail 'later failure lost durable prefix'
print -r -- ok
