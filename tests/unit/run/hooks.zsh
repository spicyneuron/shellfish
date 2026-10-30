#!/usr/bin/env zsh
source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp run-hook-contract
export SF_TEST_BACKEND_DELAY=0
sf_test_frozen_profile
typeset hook="$tmp/prompt" session stream="$tmp/stream"
sf_test_hook "$hook" '{"user_text":"${output.stdout}"}' <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 0 && $SHELLFISH_TURN_ID == <1-> && -d $SHELLFISH_TURN_STATE ]] || exit 2
input=$(cat)
case $input in
  handoff) print -r -u3 -- '{"action":"deny"}'
    print -r -u3 -- '{"action":"handoff","argv":["/usr/bin/printf","next.jsonl"]}'
    print -r -u3 -- '{"state_update":[{"name":"prompt/handoff","value":true}]}'
    print -rn -- 'handoff context' ;;
  update|bad-update)
    profile=$(head -n 1 "$SHELLFISH_SESSION" | jq -c '.profile.sandbox.write=["/tmp/reference"] | .profile') || exit 2
    [[ $input != bad-update ]] || profile='{}'
    jq -cn --argjson profile "$profile" '{action:"session_update",profile:$profile}' >&3
    print -rn -- 'update context' ;;
  fail) print -r -u3 -- '{"state_update":[{"name":"prompt/failed","value":true}],"action":"deny"}'; print -rn -u2 -- 'hook broke'; exit 3 ;;
  deny) print -r -u3 -- '{"action":"deny"}' ;;
  reason) print -r -u3 -- '{"action":"deny","reason":"prompt refused"}' ;;
  invalid) print -r -u3 -- '{"action":"allow"}' ;;
  state) print -r -u3 -- '{"state_update":[{"name":"prompt/state","value":2}]}' ;;
  interrupt) print -r -u3 -- '{"state_update":[{"name":"prompt/started","value":true}]}'
    : >"$INTERRUPT_MARKER"; sleep 30 ;;
esac
ZSH
sf_test_bind_hooks user_prompt_submit "$hook"
new_session() { session="$tmp/$1.jsonl"; sf_test_session "$session"; }
new_session deny; sf_test_run deny "$session" >"$stream" || fail 'prompt denial failed'
jq -e -s 'map(.type) == ["session","hook_result"] and
  .[1] == {type:"hook_result",lifecycle:"user_prompt_submit",id:"1",action:"deny"}' \
  "$session" >/dev/null || fail 'silent prompt denial was not durable'
sf_test_run state "$session" >"$stream" || fail 'turn after prompt denial failed'
assert_canonical_session "$session"
new_session reason; sf_test_run reason "$session" >"$stream" || fail 'prompt denial with reason failed'
jq -e -s 'map(.type) == ["session","hook_result"] and
  .[1].action == "deny" and .[1].reason == "prompt refused"' "$session" >/dev/null ||
  fail 'prompt denial reason was lost'
new_session handoff; sf_test_run handoff "$session" >"$stream" || fail 'handoff failed'
jq -eRn '[inputs | fromjson] as $e | $e[-1] == {type:"_handoff",argv:["/usr/bin/printf","next.jsonl"]} and
  any($e[]; .type == "state_update" and .name == "prompt/handoff" and .value == true) and
  $e[-2].model_text == "handoff context" and ([ $e[] | select(.type == "user") ] | length) == 0' \
  <"$stream" >/dev/null || fail 'last action or handoff durability failed'
new_session update; sf_test_run update "$session" >"$stream" || fail 'session update failed'
jq -e -s 'map(.type) == ["session","hook_result"] and .[0].profile.sandbox.write == ["/tmp/reference"]' "$session" >/dev/null &&
  jq -eRn '[inputs | fromjson][-1].type == "_session_update"' <"$stream" >/dev/null || fail 'session update did not replace header'
new_session bad-update; sf_test_run bad-update "$session" >"$stream" 2>"$tmp/update.err" && fail 'invalid update succeeded'
jq -e -s '.[-2].model_text == "update context" and
  .[-1] == {type:"error",user_text:"invalid session update"}' "$session" >/dev/null ||
  fail 'invalid update lost settled result'
new_session fail; sf_test_run fail "$session" >"$stream" 2>"$tmp/fail.err" && fail 'nonzero hook succeeded'
[[ $(<"$tmp/fail.err") == *'failed with status 3'*'hook broke'* ]] || fail 'nonzero diagnostic lost'
jq -e -s 'map(.type) == ["session","state_update","error"]' "$session" >/dev/null ||
  fail 'failed hook lost state or applied its action'
new_session invalid; sf_test_run invalid "$session" >"$stream" 2>"$tmp/invalid.err" && fail 'invalid action succeeded'
[[ $(<"$tmp/invalid.err") == *'invalid control'* ]] || fail 'invalid action lost its diagnostic'
jq -e -s 'map(.type) == ["session","error"]' "$session" >/dev/null || fail 'invalid action settled'
new_session state; sf_test_run state "$session" >"$stream" || fail 'state-only hook failed'
jq -e -s '.[1] == {type:"state_update",name:"prompt/state",value:2} and
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
jq -e -s '.[1] == {type:"state_update",name:"prompt/started",value:true} and
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
print -r -- "{\"type\":\"assistant\",\"stop\":\"end\",\"content\":[{\"type\":\"text\",\"text\":\"answer $n\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
ZSH
sf_test_hook "$stop" '{"user_text":"${output.stdout}${output.stderr}"}' <<'ZSH'
#!/usr/bin/env zsh
cat >"$STOP_INPUT"
if [[ $1 == 1 ]]; then
  print -r -u3 -- '{"action":"deny","reason":"not finished"}'
  # A silent hook shows its text to the user only.
  [[ -e $STOP_SILENT ]] && print -rn -u2 -- 'checking again' || print -rn -- 'checking again'
fi
ZSH
chmod +x "$backend"
export REQUEST_COUNT=$count STOP_INPUT=$stop_input STOP_SILENT="$tmp/silent"
SF_TEST_MODEL=$(jq -c --arg backend "${backend:h}" '.adapter=$backend' <<<"$SF_TEST_MODEL")
SF_TEST_PROFILE=$(jq -c '.hooks=[]' <<<"$SF_TEST_PROFILE")
sf_test_bind_hooks stop "$stop"
new_session stop; sf_test_run stop "$session" >"$stream" || fail 'stop continuation failed'
assert_equal 'answer 2' "$(<$stop_input)" 'stop input was not final assistant text'
assert_equal 2 "$(<$count)" 'stop did not continue provider'
jq -e -s 'map(select(.type == "hook_result") | {model_text,action,reason}) ==
  [{model_text:"checking again",action:"deny",reason:"not finished"}]' "$session" \
  >/dev/null || fail 'stop feedback did not settle'
new_session limit
SHELLFISH_MAX_REQUESTS_PER_TURN=1 sf_test_run stop "$session" >"$stream" 2>"$tmp/limit.err" &&
  fail 'request limit succeeded'
jq -e -s '.[-2].model_text == "checking again" and
  .[-1] == {type:"error",user_text:"provider request limit reached: 1"}' "$session" >/dev/null ||
  fail 'request limit lost feedback'
: >"$STOP_SILENT"
rm -f "$count"
new_session no-feedback; sf_test_run stop "$session" >"$stream" 2>"$tmp/feedback.err" && fail 'missing feedback succeeded'
assert_equal 1 "$(<$count)" 'stop without feedback requested again'
jq -e -s '.[-2].user_text == "checking again" and (.[-2] | has("model_text") | not) and
  .[-1] == {type:"error",user_text:"stop hook denied without model feedback"}' "$session" \
  >/dev/null || fail 'missing stop feedback was accepted'
# Ordered hooks see original input and preceding results. An action stops the list.
typeset hooks="$tmp/hooks" name
sf_test_hook "$hooks/one" '{"user_text":"${output.stdout}"}' <<'ZSH'
#!/usr/bin/env zsh
name=${0:h:t}; input=$(cat)
[[ $input == ordered ]] || exit 2
if [[ $name != one ]]; then
  [[ $name == two ]] && prev='one: ordered' || prev='two: ordered'
  jq -e -s --arg prev "$prev" 'any(.[]; .type == "hook_result" and .user_text == $prev)' \
    "$SHELLFISH_SESSION" >/dev/null || exit 3
fi
[[ $name != two || ! -e $FAIL_TWO ]] || exit 7
[[ $name != two || ! -e $DENY_TWO ]] || print -r -u3 -- '{"action":"deny"}'
print -rn -- "$name: $input"
ZSH
for name in two three; do
  sf_test_hook "$hooks/$name" '{"user_text":"${output.stdout}"}' <"$hooks/one/run"
done
export DENY_TWO="$tmp/deny-two" FAIL_TWO="$tmp/fail-two"
SF_TEST_MODEL=$(jq -c --arg adapter "${SF_TEST_BACKEND:h}" '.adapter=$adapter' <<<"$SF_TEST_MODEL")
SF_TEST_PROFILE=$(jq -c '.hooks=[]' <<<"$SF_TEST_PROFILE")
sf_test_bind_hooks user_prompt_submit "$hooks"/{one,two,three}
new_session ordered; sf_test_run ordered "$session" >"$stream" || fail 'ordered hooks failed'
jq -e -s 'map(select(.type == "hook_result") | .user_text) ==
  ["one: ordered","two: ordered","three: ordered"]' "$session" >/dev/null ||
  fail 'hook order or input was wrong'
: >"$DENY_TWO"; new_session denied; sf_test_run ordered "$session" >"$stream" || fail 'denial failed'
jq -e -s 'map(select(.type == "hook_result") | .user_text) == ["one: ordered","two: ordered"] and
  (map(.type) | index("user") == null)' "$session" >/dev/null || fail 'denial did not stop list'
rm "$DENY_TWO"; : >"$FAIL_TWO"; new_session later-error
sf_test_run ordered "$session" >"$stream" 2>"$tmp/later.err" && fail 'later hook succeeded'
jq -e -s 'map(select(.type == "hook_result") | .user_text) == ["one: ordered"] and
  .[-1].type == "error"' "$session" >/dev/null || fail 'later failure lost durable prefix'
rm "$FAIL_TWO"
for name in one two three; do
  print -r -- '{"on":"user_prompt_submit","match":{"pattern":"^ordered\\z"},"user_text":"${output.stdout}"}' \
    >"$hooks/$name/manifest.json"
done
new_session matched; sf_test_run ordered "$session" >"$stream" || fail 'matched hooks failed'
jq -e -s 'map(select(.type == "hook_result") | .user_text) ==
  ["one: ordered","two: ordered","three: ordered"]' "$session" >/dev/null ||
  fail 'matching hook order changed'
new_session unmatched; sf_test_run other "$session" >"$stream" || fail 'unmatched hooks failed'
jq -e -s 'all(.[]; .type != "hook_result") and any(.[]; .type == "user")' \
  "$session" >/dev/null || fail 'unmatched hooks ran or prompt was lost'
new_session multiline; sf_test_run $'ordered\n' "$session" >"$stream" ||
  fail 'multiline prompt matched exact pattern'
jq -e -s 'all(.[]; .type != "hook_result") and
  any(.[]; .type == "user" and .content[0].text == "ordered\n")' \
  "$session" >/dev/null || fail 'multiline prompt was not submitted intact'
print -r -- '{"on":"user_prompt_submit","match":{"pattern":"["}}' >"$hooks/one/manifest.json"
new_session invalid-match
sf_test_run other "$session" >"$stream" 2>"$tmp/match.err" &&
  fail 'invalid unmatched manifest succeeded'
[[ $(<"$tmp/match.err") == *'hook manifest must be valid'* ]] ||
  fail 'invalid match diagnostic was lost'
# A command runs alone, before prompt hooks, with its arguments as input.
print -r -- '{"on":"user_prompt_submit","user_text":"${output.stdout}"}' >"$hooks/one/manifest.json"
SF_TEST_PROFILE=$(jq -c '.hooks=[]' <<<"$SF_TEST_PROFILE")
sf_test_bind_hooks user_prompt_submit "$hooks/one"
sf_test_hook "$tmp/commands/go" '{"description":"Go","arguments":"[TO]","aliases":["g"],"user_text":"${input}"}' <<'ZSH'
#!/usr/bin/env zsh
input=$(cat)
[[ $# == 0 && $SHELLFISH_TURN_ID == <1-> ]] || exit 2
jq -e '.[0] == {name:"go",aliases:["g"],arguments:"[TO]",description:"Go"}' \
  <<<"$SHELLFISH_COMMANDS" >/dev/null || exit 3
[[ $input != away ]] || jq -cn '{action:"handoff",argv:["next"]}' >&3
ZSH
SF_TEST_PROFILE=$(jq -c --arg go "$tmp/commands/go" '.commands=[$go]' <<<"$SF_TEST_PROFILE")
new_session command; sf_test_run '/g  away' "$session" >"$stream" || fail 'command failed'
jq -eRn '[inputs | fromjson][-1] == {type:"_handoff",argv:["next"]}' <"$stream" >/dev/null &&
  jq -e -s 'map(.type) == ["session","hook_result"] and .[1].user_text == "away" and
    (.[1] | has("action") | not)' "$session" >/dev/null || fail 'command handoff or input was wrong'
new_session command-deny; sf_test_run /go "$session" >"$stream" || fail 'bare command failed'
jq -e -s 'map(.type) == ["session","hook_result"] and .[1].action == "deny"' \
  "$session" >/dev/null || fail 'command prompt was submitted'
cp -R "$tmp/commands/go" "$tmp/commands/g"
SF_TEST_PROFILE=$(jq -c --arg g "$tmp/commands/g" '.commands+=[$g]' <<<"$SF_TEST_PROFILE")
new_session command-duplicate
sf_test_run /go "$session" >"$stream" 2>"$tmp/duplicate.err" && fail 'duplicate command succeeded'
[[ $(<"$tmp/duplicate.err") == *'duplicate command name: /g'* ]] ||
  fail 'duplicate command diagnostic was lost'
print -r -- ok
