#!/usr/bin/env zsh

source "${0:A:h}/_subagent.zsh"

sf_test_session "$session"
sf_test_run 'parent task' "$session" >"$stream" || fail 'parent tool turn failed'
assert_canonical_session "$session"
typeset id child
id=$(jq -r -s '[.[] | select(.type == "state_update" and (.name | startswith("subagents/"))) |
  .name] | last | sub("^subagents/"; "")' "$session")
[[ $id =~ '^[a-f0-9]{32}$' ]] || fail 'subagent association was not persisted'
child="$tmp/.subagent-$id.jsonl"
[[ -f $child ]] || fail 'hidden child was not created'
assert_canonical_session "$child"
jq -e -s '
  .[0].profile.sandbox.enabled and .[0].profile.tools == [] and
  (.[1:] | map(.type)) == ["state_update","user","assistant"] and
  .[1] == {type:"state_update",name:"subagent",value:true} and
  .[2].content[0].text == "child task" and
  .[3].content[0].text == "child answer"
' "$child" >/dev/null || fail 'child profile, marker, or answer is wrong'
jq -e -n --slurpfile parent "$session" --slurpfile child "$child" '
  ($parent[0].model.provider | split("/") | last) as $provider |
  ($child[0].model | del(.provider)) == ($parent[0].model | del(.provider)) and
  ($child[0].model.provider | endswith("/" + $provider))
' >/dev/null || fail 'child did not inherit the parent model'
jq -e -s --arg id "$id" '
  ([.[] | select(.type == "tool_result" and .name == "subagent")] | last) as $result |
  ($result.model_content[0].text | fromjson) ==
    {agent_id:$id,exit_code:0,answer:"child answer"} and
  ([.[] | select(.type == "state_update" and .name == ("subagents/" + $id)) | .value]) == [true]
' "$session" >/dev/null || fail 'parent result or association is wrong'

# The hidden child is not a candidate for automatic resume discovery.
sf_test_source libexec/resume/discovery.zsh
sf_session_directory || fail 'cannot locate resume directory'
typeset resume_dir=$REPLY
mkdir -p "$resume_dir"
cp "$session" "$resume_dir/parent.jsonl"
cp "$child" "$resume_dir/.subagent-$id.jsonl"
sf_resume_find 0 || fail 'resume discovery failed'
[[ ${#SF_RESUME_MATCHES} == 1 && $SF_RESUME_MATCHES[1] == "$resume_dir/parent.jsonl" ]] ||
  fail 'hidden child appeared in resume discovery'

# A child turn that exits with a failure reports it to the parent.
typeset failed="$tmp/failed-parent.jsonl"
sf_test_session "$failed"
sf_test_run 'parent failure' "$failed" >"$stream" || fail 'failure turn failed'
assert_canonical_session "$failed"
jq -e -s '
  ([.[] | select(.type == "state_update" and (.name | startswith("subagents/"))) |
    .value]) == [true] and
  ([.[] | select(.type == "tool_result" and .name == "subagent")] | last | .exit_code) != 0
' "$failed" >/dev/null || fail 'failed child was not reported'

typeset inspected
inspected=$(print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$id\"}" |
  SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>/dev/null) || fail 'inspect failed'
jq -e --arg id "$id" '.agent_id == $id and
  .working == false and .settled == true and .answer == "child answer"' \
  <<<"$inspected" >/dev/null || fail 'inspect output is wrong'
export SF_AGENT_ID_FILE="$tmp/agent-id"
print -r -- "$id" >"$SF_AGENT_ID_FILE"
sf_test_run 'continue child' "$session" >"$stream" || fail 'first continuation failed'
sf_test_run 'continue child' "$session" >"$stream" || fail 'second continuation failed'
assert_canonical_session "$session"
assert_canonical_session "$child"
jq -e -s '
  [.[] | select(.type == "user") | .content[0].text] ==
    ["child task","next child task","next child task"] and
  [.[0].profile.sandbox.enabled, .[0].profile.tools] == [true,[]] and
  ([.[] | select(.type == "assistant" and .stop == "end") |
    .content[0].text] | length) == 3
' "$child" >/dev/null || fail 'continuation did not reuse the frozen child profile'
jq -e -s --arg id "$id" '
  ([.[] | select(.type == "state_update" and .name == ("subagents/" + $id)) |
    .value]) == [true] and
  ([.[] | select(.type == "tool_result" and .name == "subagent") |
    .model_content[0].text | fromjson | select(.agent_id == $id and .answer == "child answer")] |
    length) == 3
' "$session" >/dev/null || fail 'continuation results were not durable'
if print -r -- '{"operation":"continue","agent_id":"00000000000000000000000000000000","task":"bad"}' |
    SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>"$tmp/refused-state" >/dev/null 2>&1; then
  fail 'unknown continuation ID was accepted'
fi
[[ ! -s "$tmp/refused-state" ]] || fail 'unknown continuation wrote state'
if print -r -- '{"operation":"start","profile":"child","task":"recurse"}' |
    SHELLFISH_SESSION="$child" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'child recursion was accepted'
fi
typeset limited_session="$tmp/limited-parent.jsonl"
for value in null false 1 '[]' '"text"' '{"unknown":1}' '{"max_active":null}' \
    '{"max_active":0}' '{"max_active":-1}' '{"max_active":1.5}' \
    '{"max_active":"2"}' '{"max_active":true}'; do
  jq -c --argjson value "$value" '
    if .type == "session" then .profile.config.subagent=$value else . end
  ' "$session" >"$limited_session"
  if print -r -- '{"operation":"start","profile":"child","task":"bad limit"}' |
      SHELLFISH_SESSION="$limited_session" SHELLFISH_CONFIG="$(sf_test_session_config "$limited_session")" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
      "$agent/run" 3>"$tmp/refused-state" >"$tmp/limit.out" 2>"$tmp/limit.err"; then
    fail "invalid subagent configuration was accepted: $value"
  fi
  grep -q 'config.subagent' "$tmp/limit.err"
  [[ ! -s "$tmp/refused-state" ]] || fail 'invalid configuration wrote state'
done
jq -c 'if .type == "session" then .profile.config.subagent |= del(.max_active) else . end' \
  "$session" >"$limited_session"
# Held locks stand in for running subagents.
zmodload zsh/system || fail 'cannot load session locking'
typeset -a held=()
hold() {
  local fd
  : >"$tmp/.subagent-$1.jsonl.lock"
  zsystem flock -t 0 -f fd "$tmp/.subagent-$1.jsonl.lock" || fail "cannot hold $1"
  held+=( $fd )
  print -r -- "{\"type\":\"state_update\",\"name\":\"subagents/$1\",\"value\":true}" >>"$2"
}
for slot in 1 2 3 4; do hold occupied-$slot "$limited_session"; done
if print -r -- '{"operation":"start","profile":"child","task":"default cap"}' |
    SHELLFISH_SESSION="$limited_session" SHELLFISH_CONFIG="$(sf_test_session_config "$limited_session")" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>"$tmp/refused-state" >"$tmp/limit.out"; then
  fail 'default active-subagent limit was ignored'
fi
grep -q 'active subagent limit reached (4)' "$tmp/limit.out"
[[ ! -s "$tmp/refused-state" ]] || fail 'default cap wrote state'
jq -c 'if .type == "session" then .profile.config.subagent.max_active=1 else . end' \
  "$session" >"$limited_session"
hold occupied "$limited_session"
if print -r -- '{"operation":"start","profile":"child","task":"at cap"}' |
    SHELLFISH_SESSION="$limited_session" SHELLFISH_CONFIG="$(sf_test_session_config "$limited_session")" \
    SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'full active-subagent limit was ignored'
fi
if print -r -- "{\"operation\":\"continue\",\"agent_id\":\"$id\",\"task\":\"at cap\"}" |
    SHELLFISH_SESSION="$limited_session" SHELLFISH_CONFIG="$(sf_test_session_config "$limited_session")" \
    SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>"$tmp/refused-state" >/dev/null 2>&1; then
  fail 'continuation ignored full active-subagent limit'
fi
[[ ! -s "$tmp/refused-state" ]] || fail 'capped continuation wrote state'
print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$id\"}" |
  SHELLFISH_SESSION="$limited_session" SHELLFISH_CONFIG="$(sf_test_session_config "$limited_session")" \
  SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>/dev/null >/dev/null || fail 'inspect was blocked at the cap'
for fd in $held; do zsystem flock -u $fd; done
if print -r -- '{"operation":"inspect","agent_id":"00000000000000000000000000000000"}' |
    SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'unknown subagent ID was accepted'
fi
typeset bad_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
print -r -- "{\"type\":\"state_update\",\"name\":\"subagents/$bad_id\",\"value\":true}" >>"$session"
print -r -- '{}' >"$tmp/.subagent-$bad_id.jsonl"
if print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$bad_id\"}" |
    SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'invalid child transcript was inspected'
fi
if print -r -- "{\"operation\":\"continue\",\"agent_id\":\"$bad_id\",\"task\":\"bad\"}" |
    SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>"$tmp/refused-state" >/dev/null 2>&1; then
  fail 'invalid child transcript was continued'
fi
[[ ! -s "$tmp/refused-state" ]] || fail 'invalid child wrote state'
typeset missing_id=cccccccccccccccccccccccccccccccc
print -r -- "{\"type\":\"state_update\",\"name\":\"subagents/$missing_id\",\"value\":true}" >>"$session"
if print -r -- "{\"operation\":\"continue\",\"agent_id\":\"$missing_id\",\"task\":\"bad\"}" |
    SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>"$tmp/refused-state" >/dev/null 2>&1; then
  fail 'missing child transcript was continued'
fi
[[ ! -s "$tmp/refused-state" ]] || fail 'missing child wrote state'
if print -r -- "{\"operation\":\"continue\",\"agent_id\":\"$id\",\"task\":\"bad\",\"profile\":\"child\"}" |
    SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>"$tmp/refused-state" >/dev/null 2>&1; then
  fail 'continuation accepted a profile override'
fi

# A public parent fork carries the association; the copied parent can use it
# without copying the associated child file.
typeset copied_parent fork_actions="$tmp/fork-actions"
SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  SHELLFISH_TURN_STATE="$tmp" "$ROOT/share/commands/fork/run" \
  3>"$fork_actions" </dev/null >/dev/null ||
  fail 'parent fork failed'
copied_parent=$(jq -r 'select(.action == "handoff") | .argv[2]' "$fork_actions")
[[ -f $copied_parent ]] || fail 'parent fork did not create a session'
assert_canonical_session "$copied_parent"
sf_test_run 'continue child' "$copied_parent" >"$stream" ||
  fail 'copied parent could not continue its associated child'
assert_canonical_session "$copied_parent"
jq -e -s --arg id "$id" '
  ([.[] | select(.type == "tool_result" and .name == "subagent") |
    .model_content[0].text | fromjson | select(.agent_id == $id and .answer == "child answer")] |
    length) == 4
' "$copied_parent" >/dev/null || fail 'copied parent lost its subagent association'

# Fork and rewind keep subagents started before the cut and leave out later ones.
typeset cut_parent="$tmp/cut-parent.jsonl" cut_actions="$tmp/cut-actions" cut_copy mode
for mode in fork rewind; do
  sf_test_session "$cut_parent"
  print -r -- '{"type":"user","section":1,"content":[{"type":"text","text":"one"}]}' >>"$cut_parent"
  print -r -- '{"type":"state_update","name":"subagents/a","value":true}' >>"$cut_parent"
  print -r -- '{"type":"assistant","section":2,"content":[{"type":"text","text":"started"}],"stop":"end"}' >>"$cut_parent"
  print -r -- '{"type":"user","section":3,"content":[{"type":"text","text":"two"}]}' >>"$cut_parent"
  print -r -- '{"type":"state_update","name":"subagents/b","value":true}' >>"$cut_parent"
  print -r -- '{"type":"assistant","section":4,"content":[{"type":"text","text":"later"}],"stop":"end"}' >>"$cut_parent"
  print -rn -- 3 | SHELLFISH_SESSION="$cut_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    SHELLFISH_TURN_STATE="$tmp" "$ROOT/share/commands/$mode/run" 3>|"$cut_actions" >/dev/null ||
    fail "$mode at a later turn failed"
  cut_copy=$(jq -r 'select(.action == "handoff") | .argv[2]' "$cut_actions")
  [[ $mode == fork && $cut_copy != $cut_parent || $mode == rewind && $cut_copy == $cut_parent ]] ||
    fail "$mode handed off to the wrong session"
  assert_canonical_session "$cut_copy"
  jq -e -s '
    [.[] | select(.type == "user") | .content[0].text] == ["one"] and
    [.[] | select(.type == "state_update") | [.name, .value]] == [["subagents/a", true]]
  ' "$cut_copy" >/dev/null || fail "$mode kept the wrong subagent state"
  jq -e '.action == "handoff" and .argv[-2:] == ["--draft", "two"]' "$cut_actions" >/dev/null ||
    fail "$mode did not restore the removed prompt"
done

# A stopped child is settled even with a stop hook, which ran before it exited.
typeset stop_parent="$tmp/stop-parent.jsonl" stop_id stop_child stop_inspection
sf_test_session "$stop_parent"
sf_test_run 'stop-hook parent' "$stop_parent" >"$stream" ||
  fail 'stop-hook child start failed'
stop_id=$(jq -r -s '[.[] | select(.type == "state_update" and
  (.name | startswith("subagents/"))) | .name] | last | sub("^subagents/"; "")' "$stop_parent")
stop_child="$tmp/.subagent-$stop_id.jsonl"
stop_inspection=$(print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$stop_id\"}" |
  SHELLFISH_SESSION="$stop_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>"$tmp/refused-state") || fail 'stop-hook inspection failed'
jq -e '.working == false and .settled == true and
  .answer == "child answer" and .last_record == "hook_result"' \
  <<<$stop_inspection >/dev/null || fail 'stop-hook inspection was misreported'
print -r -- "$stop_id" >"$SF_AGENT_ID_FILE"
sf_test_run 'continue child' "$stop_parent" >"$stream" ||
  fail 'settled synchronous stop-hook child could not continue'
assert_canonical_session "$stop_child"
jq -e -s '[.[] | select(.type == "user") | .content[0].text] ==
  ["child task","next child task"]' "$stop_child" >/dev/null ||
  fail 'stop-hook continuation did not add a child turn'

# A failed follow-up must not return an earlier turn's answer.
typeset failed_result
integer failed_code=0
failed_result=$(jq -cn --arg id "$stop_id" \
  '{operation:"continue",agent_id:$id,task:"child error"}' |
  SHELLFISH_SESSION="$stop_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>"$tmp/refused-state") || failed_code=$?
(( failed_code != 0 )) || fail 'failed continuation succeeded'
jq -e --argjson code "$failed_code" '.exit_code == $code and .answer == null' \
  <<<$failed_result >/dev/null || fail 'failed continuation returned an old answer'
stop_inspection=$(jq -cn --arg id "$stop_id" '{operation:"inspect",agent_id:$id}' |
  SHELLFISH_SESSION="$stop_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>"$tmp/refused-state") || fail 'failed continuation inspection failed'
jq -en --argjson result "$failed_result" --argjson inspection "$stop_inspection" \
  '$inspection.working == false and $inspection.settled == true and
   $inspection.answer == $result.answer' >/dev/null || fail 'failed outcomes disagree'

# A denied stop can finish with a later response in the same turn.
typeset retry_result
retry_result=$(jq -cn --arg id "$stop_id" \
  '{operation:"continue",agent_id:$id,task:"retry child task"}' |
  SF_AGENT_STOP_DENY=1 SHELLFISH_SESSION="$stop_parent" \
  SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" "$agent/run" 3>"$tmp/refused-state") ||
  fail 'stop-hook retry failed'
jq -e '.exit_code == 0 and .answer == "child answer"' <<<$retry_result >/dev/null ||
  fail 'stop-hook retry lost its answer'
assert_canonical_session "$stop_child"
jq -e -s '
  ([to_entries[] | select(.value.type == "user") | .key] | last) as $turn |
  [.[$turn:][] | select(.type == "assistant")] | length == 2
' "$stop_child" >/dev/null || fail 'stop denial did not continue inference'

# Inspect durable prefixes as if the child had stopped at each boundary.
typeset outcome_id=cccccccccccccccccccccccccccccccc outcome_child outcome_result phase
outcome_child="$tmp/.subagent-$outcome_id.jsonl"
: >"$outcome_child.lock"
print -r -- "{\"type\":\"state_update\",\"name\":\"subagents/$outcome_id\",\"value\":true}" >>"$stop_parent"
for phase in pending denied finished failed; do
  jq -c -s --arg phase "$phase" '
    ([to_entries[] | select(.value.type == "user") | .key] | last) as $turn |
    ([to_entries[] | select(.value.type == "hook_result" and
      .value.lifecycle == "stop" and .value.action == "deny") | .key] | last) as $deny |
    if $phase == "pending" then .[:$turn + 1][]
    elif $phase == "denied" then .[:$deny + 1][]
    elif $phase == "failed" then .[], {type:"error",user_text:"Stop failed"}
    else .[] end
  ' "$stop_child" >"$outcome_child"
  print -r -- '{"type":"state_update","name":"check","value":true}' >>"$outcome_child"
  assert_canonical_session "$outcome_child"
  outcome_result=$(jq -cn --arg id "$outcome_id" '{operation:"inspect",agent_id:$id}' |
    SHELLFISH_SESSION="$stop_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>"$tmp/refused-state") || fail "$phase inspection failed"
  jq -e --arg phase "$phase" --argjson result "$retry_result" '
    .working == false and .last_record == "state_update" and
    .settled == ($phase == "finished" or $phase == "failed") and
    .answer == (if $phase == "finished" then $result.answer else null end)
  ' <<<$outcome_result >/dev/null || fail "$phase outcome was misreported"
done
print -r -- "$id" >"$SF_AGENT_ID_FILE"

# Without a profile, a fresh child uses the parent's, minus this tool.
typeset own_result own_id
own_result=$(print -r -- '{"operation":"start","task":"child task"}' |
  SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>/dev/null) || fail 'start with the parent profile failed'
jq -e '.answer == "child answer"' <<<"$own_result" >/dev/null || fail 'parent-profile child did not answer'
own_id=$(jq -r '.agent_id' <<<"$own_result")
jq -e -n --slurpfile parent "$session" --slurpfile child "$tmp/.subagent-$own_id.jsonl" '
  ($child[0].profile | del(.tools)) == ($parent[0].profile | del(.tools)) and
  $child[0].profile.tools == [] and
  ($child[0].model | del(.provider)) == ($parent[0].model | del(.provider)) and
  ($child[0].model.provider | endswith("/" + ($parent[0].model.provider | split("/") | last))) and
  ($child[1:] | map(.type)) == ["state_update","user","assistant"]
' >/dev/null || fail 'parent-profile child did not copy the parent profile'

# A fork inherits only the settled parent prefix, including its effective state.
typeset fork_parent="$tmp/fork-parent.jsonl" fork_request="$tmp/fork-request.json"
export SF_AGENT_REQUEST="$fork_request"
sf_test_session "$fork_parent"
print -r -- '{"type":"user","content":[{"type":"text","text":"earlier user"}]}' >>"$fork_parent"
print -r -- '{"type":"assistant","content":[{"type":"text","text":"earlier answer"}],"stop":"end"}' >>"$fork_parent"
print -r -- '{"type":"state_update","name":"subagents/old","value":true}' >>"$fork_parent"
sf_test_run 'fork parent' "$fork_parent" >"$stream" || fail 'fork parent turn failed'
assert_canonical_session "$fork_parent"
typeset fork_id fork_child
fork_id=$(jq -r -s '[.[] | select(.type == "state_update" and (.name | startswith("subagents/"))) |
  .name] | last | sub("^subagents/"; "")' "$fork_parent")
fork_child="$tmp/.subagent-$fork_id.jsonl"
assert_canonical_session "$fork_child"
jq -e -s --slurpfile parent "$fork_parent" '
  .[0] == ($parent[0] | .profile.tools = []) and
  (.[1:4] == $parent[1:4]) and
  .[4] == {type:"state_update",name:"subagent",value:true} and
  (.[5:] | map(.type)) == ["user","assistant"] and
  .[5].content[0].text == "delegated task" and
  .[6].content[0].text == "fork answer"
' "$fork_child" >/dev/null || fail 'fork copied an incorrect prefix'
jq -e '
  [.messages[] | select(.type == "user" or .type == "assistant") |
    .content[0].text] == ["earlier user","earlier answer","delegated task"]
' "$fork_request" >/dev/null || fail 'fork provider context is wrong'

typeset header_parent="$tmp/header-parent.jsonl" header_id header_child
sf_test_session "$header_parent"
sf_test_run 'fork header' "$header_parent" >"$stream" || fail 'header-only fork failed'
header_id=$(jq -r -s '[.[] | select(.type == "state_update" and (.name | startswith("subagents/"))) |
  .name] | last | sub("^subagents/"; "")' "$header_parent")
header_child="$tmp/.subagent-$header_id.jsonl"
assert_canonical_session "$header_child"
jq -e -s 'map(.type) == ["session","state_update","user","assistant"] and
  .[2].content[0].text == "delegated task"' "$header_child" >/dev/null ||
  fail 'header-only fork inherited the invoking turn'

typeset recovered_parent="$tmp/recovered-parent.jsonl" recovered_id
sf_test_session "$recovered_parent"
print -r -- '{"type":"user","content":[{"type":"text","text":"interrupted"}]}' >>"$recovered_parent"
print -r -- '{"type":"error","user_text":"Turn interrupted."}' >>"$recovered_parent"
sf_test_run 'fork parent' "$recovered_parent" >"$stream" || fail 'recovered fork failed'
recovered_id=$(jq -r -s '[.[] | select(.type == "state_update" and (.name | startswith("subagents/"))) |
  .name] | last | sub("^subagents/"; "")' "$recovered_parent")
assert_canonical_session "$tmp/.subagent-$recovered_id.jsonl"
jq -e -s 'map(.type) == ["session","user","error","state_update","user","assistant"]' \
  "$tmp/.subagent-$recovered_id.jsonl" >/dev/null || fail 'recovered prefix was not inherited'
if print -r -- '{"operation":"start","profile":"child","fork":true,"task":"bad"}' |
    SHELLFISH_SESSION="$fork_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'both fork origins were accepted'
fi
# A model-chosen profile cannot be a path or leave profiles/.
for profile in "$tmp/evil.jsonc" '~/evil.jsonc' '@profiles/coding.jsonc' '../evil'; do
  if jq -cn --arg profile "$profile" '{operation:"start",profile:$profile,task:"bad"}' |
      SHELLFISH_SESSION="$fork_parent" SHELLFISH_CONFIG="$(sf_test_session_config "$fork_parent")" \
      SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" "$agent/run" 3>/dev/null >/dev/null 2>&1; then
    fail "subagent accepted profile reference: $profile"
  fi
done
if print -r -- '{"operation":"start","fork":false,"task":"bad"}' |
    SHELLFISH_SESSION="$fork_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'false fork origin was accepted'
fi

# list reports the configured choices, and only those can start.
typeset choices model_result model_id
choices=$(print -r -- '{"operation":"list"}' |
  SHELLFISH_SESSION="$fork_parent" SHELLFISH_CONFIG="$(sf_test_session_config "$fork_parent")" \
  SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" "$agent/run" 3>/dev/null) || fail 'list failed'
jq -e '. == {profiles:{child:"Test child","child-stop":"Test child with a stop hook"},
  models:{alt:"Alternate test model"}}' <<<"$choices" >/dev/null ||
  fail 'list did not report the configured choices'
for input in '{"operation":"start","profile":"unlisted","task":"bad"}' \
    '{"operation":"start","profile":"child","model":"unlisted","task":"bad"}' \
    '{"operation":"start","fork":true,"model":"alt","task":"bad"}' \
    '{"operation":"list","task":"bad"}'; do
  if print -r -- "$input" |
      SHELLFISH_SESSION="$fork_parent" SHELLFISH_CONFIG="$(sf_test_session_config "$fork_parent")" \
      SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" "$agent/run" 3>"$tmp/refused-state" >/dev/null 2>&1; then
    fail "unavailable choice was accepted: $input"
  fi
  [[ ! -s "$tmp/refused-state" ]] || fail "unavailable choice wrote state: $input"
done
model_result=$(print -r -- '{"operation":"start","profile":"child","model":"alt","task":"child task"}' |
  SHELLFISH_SESSION="$fork_parent" SHELLFISH_CONFIG="$(sf_test_session_config "$fork_parent")" \
  SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" "$agent/run" 3>/dev/null) ||
  fail 'start with a listed model failed'
jq -e '.answer == "child answer"' <<<"$model_result" >/dev/null || fail 'chosen-model child did not answer'
model_id=$(jq -r '.agent_id' <<<"$model_result")
head -n 1 "$tmp/.subagent-$model_id.jsonl" | jq -e '.model.request.model == "alt-model"' >/dev/null ||
  fail 'subagent did not use the chosen model'

# The public run boundary rejects a structurally invalid copied prefix.
typeset bad_parent="$tmp/bad-parent.jsonl" bad_events="$tmp/bad-events"
sf_test_session "$bad_parent"
print -r -- '{}' >>"$bad_parent"
print -r -- '{"type":"user","content":[{"type":"text","text":"fork now"}]}' >>"$bad_parent"
: >"$bad_events"
(
  integer tries=0
  while (( tries < 500 )); do
    if [[ -s $bad_events ]]; then
      jq -c '.state_update[0] | {type:"state_update",name,value}' <"$bad_events" >>"$bad_parent"
      exit $?
    fi
    sleep 0.01
    (( ++tries ))
  done
  exit 1
) &
typeset watcher=$!
if print -r -- '{"operation":"start","fork":true,"task":"delegated task"}' |
    SHELLFISH_SESSION="$bad_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>"$bad_events" >/dev/null 2>&1; then
  fail 'noncanonical completed prefix ran a child turn'
fi
wait "$watcher" || fail 'reservation watcher failed'
typeset bad_child_id
bad_child_id=$(jq -r '.state_update[0].name | sub("^subagents/"; "")' <"$bad_events" | head -1)
jq -e -s 'map(.type) == ["session",null,"state_update"]' "$tmp/.subagent-$bad_child_id.jsonl" \
  >/dev/null || fail 'invalid source was not copied for public validation'

typeset malformed_parent="$tmp/malformed-parent.jsonl"
sf_test_session "$malformed_parent"
print -r -- '{broken' >>"$malformed_parent"
if print -r -- '{"operation":"start","fork":true,"task":"bad"}' |
    SHELLFISH_SESSION="$malformed_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'malformed parent JSON was accepted'
fi
