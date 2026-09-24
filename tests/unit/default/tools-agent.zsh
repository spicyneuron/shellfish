#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp default-tools-agent
sf_test_config
export XDG_STATE_HOME="$tmp/state"

typeset agent="$ROOT/share/profiles/default/tools/agent"
typeset backend="$tmp/backend" session="$tmp/parent.jsonl" stream="$tmp/stream"
if grep -q '"agent"' "$ROOT/share/profiles/default/profile.jsonc"; then
  fail 'agent must be opt-in'
fi
mkdir -p "$backend"
print -r -- '{"endpoint":"https://example.invalid/test"}' >"$backend/manifest.json"
cat >"$backend/run" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
task=$(jq -r '[.messages[] | select(.type == "user") | .content[0].text] | last' <<<"$request")
if [[ $task == 'delegated task' ]]; then
  print -r -- "$request" >"$SF_AGENT_REQUEST"
  print -r -- '{"type":"_assistant_message_delta","index":0,"text":"fork answer"}'
  print -r -- '{"type":"_assistant_end","stop":"end"}'
  exit 0
fi
if jq -e '.tools | any(.name == "agent")' <<<"$request" >/dev/null; then
  if jq -e '.messages | any(.type == "tool_result")' <<<"$request" >/dev/null; then
    print -r -- '{"type":"_assistant_message_delta","index":0,"text":"parent done"}'
    print -r -- '{"type":"_assistant_end","stop":"end"}'
  else
    if [[ $task == 'fork parent' || $task == 'fork header' ]]; then
      print -r -- '{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"agent","input":"{\"operation\":\"start\",\"fork\":true,\"task\":\"delegated task\"}"}'
    else
      [[ $task != 'parent failure' ]] || task='child error'
      [[ $task == 'child error' ]] || task='child task'
      jq -cn --arg task "$task" '{type:"_assistant_tool_call_delta",index:0,
        id:"call_1",name:"agent",input:({operation:"start",profile:"child",task:$task} | tojson)}'
    fi
    print -r -- '{"type":"_assistant_end","stop":"tool_calls"}'
  fi
else
  if jq -e '[.messages[] | select(.type == "user") | .content[0].text] |
      last == "child error"' <<<"$request" >/dev/null; then
    exit 7
  fi
  print -r -- '{"type":"_assistant_message_delta","index":0,"text":"child answer"}'
  print -r -- '{"type":"_assistant_end","stop":"end"}'
fi
ZSH
chmod +x "$backend/run"
sf_test_profile child "{
  \"backend\":{\"adapter\":\"$backend\"},
  \"request\":{\"model\":\"test\"},
  \"tools\":[],\"sandbox\":true,
  \"max_requests_per_turn\":4,\"max_tool_calls_per_request\":4,
  \"max_capture_bytes\":4096
}"

sf_test_frozen_profile
SF_TEST_PROFILE=$(jq -c --arg adapter "$backend" --arg tool "$agent" \
  '.backend.adapter=$adapter | .tools=[$tool]' <<<"$SF_TEST_PROFILE")
sf_test_session "$session"
sf_test_run 'parent task' "$session" >"$stream" || fail 'parent tool turn failed'
assert_canonical_session "$session"
typeset id child
id=$(jq -r -s '[.[] | select(.type == "state" and (.name | startswith("agents/")) and
  .value.active == false) | .name] | last | sub("^agents/"; "")' "$session")
[[ $id =~ '^[a-f0-9]{32}$' ]] || fail 'agent association was not persisted'
child="$tmp/.agent-$id.jsonl"
[[ -f $child ]] || fail 'hidden child was not created'
assert_canonical_session "$child"
jq -e -s '
  .[0].profile.sandbox == true and .[0].profile.tools == [] and
  (.[1:] | map(.type)) == ["state","user","assistant"] and
  .[1] == {type:"state",name:"agents/child",value:true} and
  .[2].content[0].text == "child task" and
  .[3].content[0].text == "child answer"
' "$child" >/dev/null || fail 'child profile, marker, or answer is wrong'
jq -e -s --arg id "$id" '
  ([.[] | select(.type == "tool_result" and .name == "agent")] | last) as $result |
  ($result.model_text | fromjson) ==
    {agent_id:$id,exit_code:0,answer:"child answer"} and
  ([.[] | select(.type == "state" and .name == ("agents/" + $id)) | .value.active]) ==
    [true,false]
' "$session" >/dev/null || fail 'parent result or slot transitions are wrong'

# The hidden child is not a candidate for automatic resume discovery.
source "$ROOT/libexec/resume/discovery.zsh"
sf_session_directory || fail 'cannot locate resume directory'
typeset resume_dir=$REPLY
mkdir -p "$resume_dir"
cp "$session" "$resume_dir/parent.jsonl"
cp "$child" "$resume_dir/.agent-$id.jsonl"
sf_resume_find 0 || fail 'resume discovery failed'
[[ ${#SF_RESUME_MATCHES} == 1 && $SF_RESUME_MATCHES[1] == "$resume_dir/parent.jsonl" ]] ||
  fail 'hidden child appeared in resume discovery'

# The reservation is released after a child turn exits with a known failure.
typeset failed="$tmp/failed-parent.jsonl"
sf_test_session "$failed"
sf_test_run 'parent failure' "$failed" >"$stream" || fail 'failure turn failed'
assert_canonical_session "$failed"
jq -e -s '
  ([.[] | select(.type == "state" and (.name | startswith("agents/"))) |
    .value.active]) == [true,false] and
  ([.[] | select(.type == "tool_result" and .name == "agent")] | last | .exit_code) != 0
' "$failed" >/dev/null || fail 'failed child retained its reservation'

typeset inspected
inspected=$(print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$id\"}" |
  SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>/dev/null) || fail 'inspect failed'
jq -e --arg id "$id" '.agent_id == $id and .active == false and
  .answer == "child answer"' <<<"$inspected" >/dev/null || fail 'inspect output is wrong'
if print -r -- '{"operation":"start","profile":"child","task":"recurse"}' |
    SHELLFISH_SESSION="$child" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'child recursion was accepted'
fi
if print -r -- '{"operation":"start","profile":"child","task":"bad limit"}' |
    SHELLFISH_MAX_ACTIVE_AGENTS=0 SHELLFISH_SESSION="$session" \
    SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'invalid active-agent limit was accepted'
fi
print -r -- '{"type":"state","name":"agents/occupied","value":{"session":".agent-occupied.jsonl","active":true}}' \
  >>"$session"
if print -r -- '{"operation":"start","profile":"child","task":"at cap"}' |
    SHELLFISH_MAX_ACTIVE_AGENTS=1 SHELLFISH_SESSION="$session" \
    SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'full active-agent limit was ignored'
fi
print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$id\"}" |
  SHELLFISH_MAX_ACTIVE_AGENTS=1 SHELLFISH_SESSION="$session" \
  SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>/dev/null >/dev/null || fail 'inspect was blocked at the cap'
if print -r -- '{"operation":"inspect","agent_id":"00000000000000000000000000000000"}' |
    SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'unknown agent ID was accepted'
fi
typeset bad_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
print -r -- "{\"type\":\"state\",\"name\":\"agents/$bad_id\",\"value\":{\"session\":\".agent-$bad_id.jsonl\",\"active\":false}}" >>"$session"
print -r -- '{}' >"$tmp/.agent-$bad_id.jsonl"
if print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$bad_id\"}" |
    SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'invalid child transcript was inspected'
fi
if print -r -- '{"operation":"start","task":"missing profile"}' |
    SHELLFISH_SESSION="$session" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'missing profile was accepted'
fi

# A fork inherits only the settled parent prefix, including its effective state.
typeset fork_parent="$tmp/fork-parent.jsonl" fork_request="$tmp/fork-request.json"
export SF_AGENT_REQUEST="$fork_request"
sf_test_session "$fork_parent"
print -r -- '{"type":"user","content":[{"type":"text","text":"earlier user"}]}' >>"$fork_parent"
print -r -- '{"type":"assistant","content":[{"type":"text","text":"earlier answer"}],"stop":"end"}' >>"$fork_parent"
print -r -- '{"type":"state","name":"agents/old","value":{"session":".agent-old.jsonl","active":false}}' >>"$fork_parent"
sf_test_run 'fork parent' "$fork_parent" >"$stream" || fail 'fork parent turn failed'
assert_canonical_session "$fork_parent"
typeset fork_id fork_child
fork_id=$(jq -r -s '[.[] | select(.type == "state" and (.name | startswith("agents/")) and
  .value.active == false) | .name] | last | sub("^agents/"; "")' "$fork_parent")
fork_child="$tmp/.agent-$fork_id.jsonl"
assert_canonical_session "$fork_child"
jq -e -s --slurpfile parent "$fork_parent" '
  .[0] == $parent[0][0] and
  (.[1:4] == $parent[0][1:4]) and
  .[4] == {type:"state",name:"agents/child",value:true} and
  (.[5:] | map(.type)) == ["user","assistant"] and
  .[5].content[0].text == "delegated task" and
  .[6].content[0].text == "fork answer"
' "$fork_child" >/dev/null || fail 'fork copied an incorrect prefix'
jq -e '
  [.messages[] | select(.type == "user" or .type == "assistant") |
    .content[0].text] == ["earlier user","earlier answer","delegated task"]
' "$fork_request" >/dev/null || fail 'fork backend context is wrong'

typeset header_parent="$tmp/header-parent.jsonl" header_id header_child
sf_test_session "$header_parent"
sf_test_run 'fork header' "$header_parent" >"$stream" || fail 'header-only fork failed'
header_id=$(jq -r -s '[.[] | select(.type == "state" and (.name | startswith("agents/")) and
  .value.active == false) | .name] | last | sub("^agents/"; "")' "$header_parent")
header_child="$tmp/.agent-$header_id.jsonl"
assert_canonical_session "$header_child"
jq -e -s 'map(.type) == ["session","state","user","assistant"] and
  .[2].content[0].text == "delegated task"' "$header_child" >/dev/null ||
  fail 'header-only fork inherited the invoking turn'

typeset recovered_parent="$tmp/recovered-parent.jsonl" recovered_id
sf_test_session "$recovered_parent"
print -r -- '{"type":"user","content":[{"type":"text","text":"interrupted"}]}' >>"$recovered_parent"
print -r -- '{"type":"error","user_text":"Turn interrupted."}' >>"$recovered_parent"
sf_test_run 'fork parent' "$recovered_parent" >"$stream" || fail 'recovered fork failed'
recovered_id=$(jq -r -s '[.[] | select(.type == "state" and (.name | startswith("agents/")) and
  .value.active == false) | .name] | last | sub("^agents/"; "")' "$recovered_parent")
assert_canonical_session "$tmp/.agent-$recovered_id.jsonl"
jq -e -s 'map(.type) == ["session","user","error","state","user","assistant"]' \
  "$tmp/.agent-$recovered_id.jsonl" >/dev/null || fail 'recovered prefix was not inherited'
if print -r -- '{"operation":"start","profile":"child","fork":true,"task":"bad"}' |
    SHELLFISH_SESSION="$fork_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'both fork origins were accepted'
fi
if print -r -- '{"operation":"start","fork":false,"task":"bad"}' |
    SHELLFISH_SESSION="$fork_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'false fork origin was accepted'
fi

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
      jq -c '.state[0] | {type:"state",name,value}' <"$bad_events" >>"$bad_parent"
      exit $?
    fi
    sleep 0.01
    (( tries++ ))
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
bad_child_id=$(jq -r '.state[0].name | sub("^agents/"; "")' <"$bad_events")
jq -e -s 'map(.type) == ["session",null,"state"]' "$tmp/.agent-$bad_child_id.jsonl" \
  >/dev/null || fail 'invalid source was not copied for public validation'

typeset malformed_parent="$tmp/malformed-parent.jsonl"
sf_test_session "$malformed_parent"
print -r -- '{broken' >>"$malformed_parent"
if print -r -- '{"operation":"start","fork":true,"task":"bad"}' |
    SHELLFISH_SESSION="$malformed_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1; then
  fail 'malformed parent JSON was accepted'
fi
