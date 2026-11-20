#!/usr/bin/env zsh

source "${0:A:h}/_subagent.zsh"

zmodload zsh/system

# A background start returns while the child is still working. The child counts
# toward the cap while its turn runs and frees the slot when it ends.
typeset background_parent="$tmp/background-parent.jsonl" background_id background_child
export SF_AGENT_ID_FILE="$tmp/agent-id" SF_AGENT_RELEASE="$tmp/release"
SF_TEST_PROFILE=$(jq -c '.config.subagent.max_active=1' <<<"$SF_TEST_PROFILE")
sf_test_session "$background_parent"
if [[ $OSTYPE == darwin* || $OSTYPE == linux* && $+commands[setsid] -ne 0 ]]; then
sf_test_run 'background parent' "$background_parent" >"$stream" ||
  fail 'background parent turn failed'
background_id=$(jq -r -s '[.[] | select(.type == "state_update" and
  (.name | startswith("subagents/"))) | .name] | last | sub("^subagents/"; "")' "$background_parent")
[[ $background_id =~ '^[a-f0-9]{32}$' ]] || fail 'background ID was not persisted'
background_child="$tmp/.subagent-$background_id.jsonl"
jq -e -s --arg id "$background_id" '
  ([.[] | select(.type == "state_update" and .name == ("subagents/" + $id)) |
    .value]) == [true] and
  ([.[] | select(.type == "tool_result" and .name == "subagent")] | last |
    .model_text | fromjson) == {agent_id:$id,working:true,settled:false}
' "$background_parent" >/dev/null || fail 'background start result is wrong'
  jq -e -s 'any(.[]; .type == "assistant") | not' "$background_child" >/dev/null ||
    fail 'background start waited for child answer'
  print -r -- "$background_id" >"$SF_AGENT_ID_FILE"
  if print -r -- '{"operation":"start","profile":"child","task":"at cap"}' |
      SHELLFISH_SESSION="$background_parent" SHELLFISH_CONFIG="$(sf_test_session_config "$background_parent")" \
      SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
      "$agent/run" 3>/dev/null >/dev/null 2>&1; then
    fail 'running background child did not count toward the cap'
  fi
  typeset pending
  pending=$(print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$background_id\"}" |
    SHELLFISH_SESSION="$background_parent" SHELLFISH_CONFIG="$(sf_test_session_config "$background_parent")" \
    SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" "$agent/run" 3>/dev/null) ||
    fail 'inspect at background cap failed'
  jq -e '.working == true and .settled == false and .answer == null' \
    <<<$pending >/dev/null || fail 'pending inspection misreported completion'
  : >"$SF_AGENT_RELEASE"
  integer waited=0
  until jq -e -s '.[-1].type == "assistant" and .[-1].stop == "end"' \
      "$background_child" >/dev/null 2>&1; do
    (( waited++ < 100 )) || fail 'background child did not finish'
    sleep 0.1
  done
  until ! jq -e '.working' <<<"$(print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$background_id\"}" |
      SHELLFISH_SESSION="$background_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
      "$agent/run" 3>/dev/null)" >/dev/null; do
    (( waited++ < 100 )) || fail 'background child did not release its lock'
    sleep 0.1
  done
  print -r -- '{"operation":"start","profile":"child","task":"after background"}' |
    SHELLFISH_SESSION="$background_parent" SHELLFISH_CONFIG="$(sf_test_session_config "$background_parent")" \
    SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>/dev/null >/dev/null 2>&1 ||
    fail 'finished background child still counted toward the cap'
  sf_test_run 'inspect child' "$background_parent" >"$stream" ||
    fail 'settled background inspection failed'
  jq -e -s '
    [.[] | select(.type == "tool_result" and .name == "subagent")] | last |
      .model_text | fromjson |
      .working == false and .settled == true and .answer == "child answer"
  ' "$background_parent" >/dev/null || fail 'settled background inspection is wrong'
  rm -f -- "$SF_AGENT_RELEASE"
  sf_test_run 'continue background' "$background_parent" >"$stream" ||
    fail 'background continuation failed'
  jq -e -s --arg id "$background_id" '
    ([.[] | select(.type == "state_update" and .name == ("subagents/" + $id)) |
      .value]) == [true] and
    ([.[] | select(.type == "tool_result" and .name == "subagent")] | last |
      .model_text | fromjson) == {agent_id:$id,working:true,settled:false}
  ' "$background_parent" >/dev/null || fail 'background continuation result is wrong'
  if print -r -- "{\"operation\":\"continue\",\"agent_id\":\"$background_id\",\"task\":\"overlap\"}" |
      SHELLFISH_SESSION="$background_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
      "$agent/run" 3>"$tmp/refused-state" >/dev/null 2>&1; then
    fail 'running child was continued again'
  fi
  [[ ! -s "$tmp/refused-state" ]] || fail 'running child wrote state'
  : >"$SF_AGENT_RELEASE"
  integer continue_waited=0
  until jq -e -s '[.[] | select(.type == "assistant" and .stop == "end")] | length == 2' \
      "$background_child" >/dev/null 2>&1; do
    (( continue_waited++ < 100 )) || fail 'background continuation did not finish'
    sleep 0.1
  done
  sf_test_run 'inspect child' "$background_parent" >"$stream" ||
    fail 'background continuation inspection failed'
  jq -e -s '
    [.[] | select(.type == "tool_result" and .name == "subagent")] | last |
      .model_text | fromjson | .settled == true
  ' "$background_parent" >/dev/null || fail 'background continuation did not settle'
fi

# A final-looking assistant is not settled while the turn lock is held.
if [[ $OSTYPE == darwin* || $OSTYPE == linux* && $+commands[setsid] -ne 0 ]]; then
typeset uncertain_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb uncertain
uncertain="$tmp/.subagent-$uncertain_id.jsonl"
cp "$background_child" "$uncertain"
: >"$uncertain.lock"
zmodload zsh/system || fail 'cannot load session locking'
typeset uncertain_fd=''
zsystem flock -t 0 -f uncertain_fd "$uncertain.lock" ||
  fail 'cannot hold uncertain child lock'
print -r -- "{\"type\":\"state_update\",\"name\":\"subagents/$uncertain_id\",\"value\":true}" >>"$background_parent"
typeset uncertain_result
uncertain_result=$(print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$uncertain_id\"}" |
  SHELLFISH_SESSION="$background_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>"$tmp/uncertain-state") || fail 'uncertain inspection failed'
jq -e '.working == true and .settled == false and
  .answer == "child answer"' \
  <<<$uncertain_result >/dev/null || fail 'a locked child was reported settled'
[[ ! -s "$tmp/uncertain-state" ]] || fail 'uncertain inspection wrote state'
if print -r -- "{\"operation\":\"continue\",\"agent_id\":\"$uncertain_id\",\"task\":\"bad\"}" |
    SHELLFISH_SESSION="$background_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
    "$agent/run" 3>"$tmp/refused-state" >/dev/null 2>&1; then
  fail 'uncertain child was continued'
fi
[[ ! -s "$tmp/refused-state" ]] || fail 'uncertain continuation wrote state'
zsystem flock -u "$uncertain_fd"
uncertain_result=$(print -r -- "{\"operation\":\"inspect\",\"agent_id\":\"$uncertain_id\"}" |
  SHELLFISH_SESSION="$background_parent" SHELLFISH_EXECUTABLE="$ROOT/bin/shellfish" \
  "$agent/run" 3>"$tmp/uncertain-state") || fail 'finished child inspection failed'
jq -e '.working == false and .settled == true' \
  <<<"$uncertain_result" >/dev/null || fail 'finished child was reported running'

typeset cancel_parent="$tmp/cancel-parent.jsonl" cancel_id cancel_child
sf_test_session "$cancel_parent"
rm -f -- "$SF_AGENT_RELEASE"
cancel_id=$(SHELLFISH_CONFIG="$(sf_test_session_config "$cancel_parent")" python3 - "$agent/run" "$ROOT/bin/shellfish" "$cancel_parent" \
  "$tmp/cancel-events" <<'PY'
import json
import os
import signal
import subprocess
import sys
import time

agent, shellfish, parent, events = sys.argv[1:]
env = dict(os.environ, SHELLFISH_SESSION=parent, SHELLFISH_EXECUTABLE=shellfish)
process = subprocess.Popen(
    ["/bin/zsh", "-c", '"$1" 3>"$2"; sleep 10', "--", agent, events],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, start_new_session=True, env=env,
)
process.stdin.write(json.dumps({"operation": "start", "profile": "child",
                                "task": "slow child", "background": True}) + "\n")
process.stdin.close()
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    if os.path.exists(events):
        with open(events) as stream:
            lines = stream.readlines()
        if lines:
            state = json.loads(lines[0])["state_update"][0]
            with open(parent, "a") as stream:
                stream.write(json.dumps({"type": "state_update", **state}) + "\n")
            break
    time.sleep(.01)
else:
    raise AssertionError("reservation was not emitted")
out = process.stdout.readline()
id = json.loads(out)["agent_id"]
assert process.poll() is None, "initiating group exited before cancellation"
os.killpg(process.pid, signal.SIGTERM)
assert process.wait(timeout=10) != 0, "initiating group ignored cancellation"
print(id)
PY
) || fail 'cancelled parent did not launch background child'
: >"$SF_AGENT_RELEASE"
cancel_child="$tmp/.subagent-$cancel_id.jsonl"
integer cancel_waited=0
until jq -e -s '.[-1].type == "assistant" and .[-1].stop == "end"' \
    "$cancel_child" >/dev/null 2>&1; do
  (( cancel_waited++ < 100 )) || fail 'background child died with initiating group'
  sleep 0.1
done
fi

# A failed background launch reports its error and leaves nothing running.
typeset fail_launcher="$tmp/fail-launcher" fail_parent="$tmp/fail-launch-parent.jsonl"
cat >"$fail_launcher" <<'ZSH'
#!/usr/bin/env zsh
if [[ $1 == run && $2 == --background ]]; then
  print -u2 -- 'background launch failed'
  exit 7
fi
exec "$SF_TEST_REAL_SHELLFISH" "$@"
ZSH
chmod +x "$fail_launcher"
export SF_TEST_REAL_SHELLFISH="$ROOT/bin/shellfish"
sf_test_session "$fail_parent"
typeset fail_events="$tmp/fail-events"
: >"$fail_events"
(
  integer seen=0 tries=0
  while (( seen < 1 && tries < 500 )); do
    typeset line
    line=$(sed -n "$(( seen + 1 ))p" "$fail_events")
    if [[ -n $line ]]; then
      (( seen += 1 ))
      jq -c '.state_update[0] | {type:"state_update",name,value}' <<<"$line" >>"$fail_parent"
      continue
    fi
    sleep 0.01
    (( tries += 1 ))
  done
  (( seen == 1 ))
) &
typeset fail_watcher=$!
if print -r -- '{"operation":"start","profile":"child","task":"never","background":true}' |
    SHELLFISH_SESSION="$fail_parent" SHELLFISH_CONFIG="$(sf_test_session_config "$fail_parent")" \
    SHELLFISH_EXECUTABLE="$fail_launcher" \
    "$agent/run" 3>"$fail_events" >/dev/null 2>"$tmp/fail-error"; then
  fail 'failed launch succeeded'
fi
wait "$fail_watcher" || fail 'failed launch did not record its subagent'
grep -q 'background launch failed' "$tmp/fail-error" ||
  fail 'launch error was not reported'
jq -e -s '[.[] | select(.type == "state_update" and (.name | startswith("subagents/"))) |
  .value] == [true]' "$fail_parent" >/dev/null ||
  fail 'failed launch wrote unexpected state'
