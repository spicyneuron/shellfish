#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-turn-contract
export SF_TEST_PROVIDER_DELAY=0

# A successful turn appends each durable object before emitting it.
sf_test_frozen_profile
typeset session="$tmp/simple.jsonl" stream="$tmp/simple.stream"
sf_test_session "$session"
integer prefix=$(wc -l <"$session")
sf_test_run $'two\nwords' "$session" >"$stream" || fail 'simple turn failed'
jq -eRn -L "$ROOT" '
  include "lib/session";
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "user" or .type == "assistant"))) as $durable |
  $durable[0] == {type:"user",content:[{type:"text",text:"two\nwords"}]} and
  ($durable[1] | .type == "assistant" and .stop == "end" and
    (.usage | token_usage)) and
  ($events | any(.type == "_assistant_message_delta"))
' <"$stream" >/dev/null || fail 'simple turn emitted the wrong objects'
jq -c 'select(.type | startswith("_") | not)' "$stream" >"$tmp/emitted"
tail -n +$(( prefix + 1 )) "$session" | jq -c . >"$tmp/appended"
cmp -s "$tmp/emitted" "$tmp/appended" ||
  fail 'durable events differ from appended records'

# Complete calls execute in assistant order and all settle before continuation.
typeset provider="$tmp/provider/run" tool="$tmp/ordered/run" order="$tmp/order"
mkdir -p "${provider:h}" "${tool:h}"
cat >"$provider" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
if jq -e '.messages | any(.type == "tool_result")' <<<"$request" >/dev/null; then
  jq -e '
    .messages[-4:] == [
      {type:"tool_call",id:"call_1",name:"ordered",input:{value:"first"}},
      {type:"tool_result",call_id:"call_1",name:"ordered",content:"first",exit_code:0},
      {type:"tool_call",id:"call_2",name:"ordered",input:{value:"second"}},
      {type:"tool_result",call_id:"call_2",name:"ordered",content:"second",exit_code:0}
    ]
  ' <<<"$request" >/dev/null || exit 9
  [[ $(<$TOOL_ORDER) == $'first\nsecond' ]] || exit 8
  print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":2,"output_tokens":1}}'
else
  print -r -- '{"type":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"ordered","input":{"value":"first"}},{"type":"tool_call","id":"call_2","name":"ordered","input":{"value":"second"}}],"usage":{"input_tokens":1,"output_tokens":1}}'
fi
ZSH
cat >"$tool" <<'ZSH'
#!/usr/bin/env zsh
value=$(jq -er '.value | select(type == "string")') || exit 2
print -r -- "$value" >>"$TOOL_ORDER"
print -rn -u3 -- "{\"state_update\":[{\"name\":\"tool/$value\",\"value\":true}]}"
print -rn -- "$value"
ZSH
chmod +x "$provider" "$tool"
print -r -- '{
  "description": "Record ordered calls",
  "input_schema": {"type": "object", "additionalProperties": false, "required": ["value"],
    "properties": {"value": {"type": "string"}}},
  "environment": ["TOOL_ORDER"],
  "user_text": "Ordered ${input.value}",
  "sandbox": false
}' >"${tool:h}/manifest.json"
SF_TEST_MODEL=$(jq -c --arg provider "${provider:h}" '.provider=$provider' <<<"$SF_TEST_MODEL")
SF_TEST_PROFILE=$(jq -c --arg tool "${tool:h}" '.tools=[$tool]' <<<"$SF_TEST_PROFILE")
export TOOL_ORDER=$order
session="$tmp/ordered.jsonl"
sf_test_session "$session"
sf_test_run ordered "$session" >"$stream" || fail 'ordered tool turn failed'
jq -eRn '
  [inputs | fromjson] as $events |
  [$events[] | select(.type | IN("assistant","_draft","state_update","tool_result")) |
    if .type == "assistant" then [.type,.stop]
    elif .type == "state_update" then [.type,.name]
    else [.type,.id,.name,.exit_code?] end] == [
      ["assistant","tool_calls"],
      ["_draft","call_1","ordered",null],
      ["state_update","tool/first"],
      ["tool_result","call_1","ordered",0],
      ["_draft","call_2","ordered",null],
      ["state_update","tool/second"],
      ["tool_result","call_2","ordered",0],
      ["assistant","end"]
    ] and
  ($events | map(select(.type == "tool_result") | .input)) ==
    [{value:"first"},{value:"second"}] and
  ($events | map(select(.type == "tool_result") | [.user_text,.model_text])) ==
    [["Ordered first","first"],["Ordered second","second"]]
' <"$stream" >/dev/null || fail 'tool calls did not settle in order'
assert_canonical_session "$session"

# Unknown tools and calls beyond the per-request limit settle as denials.
typeset limited_provider="$tmp/limited-provider/run"
mkdir -p "${limited_provider:h}"
cat >"$limited_provider" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
if jq -e '.messages | any(.type == "tool_result")' <<<"$request" >/dev/null; then
  print -r -- '{"type":"assistant","stop":"end","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":2,"output_tokens":1}}'
else
  print -r -- '{"type":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_1","name":"missing","input":{}},{"type":"tool_call","id":"call_2","name":"missing","input":{}}],"usage":{"input_tokens":1,"output_tokens":1}}'
fi
ZSH
chmod +x "$limited_provider"
SF_TEST_MODEL=$(jq -c --arg provider "${limited_provider:h}" '.provider=$provider' <<<"$SF_TEST_MODEL")
SF_TEST_PROFILE=$(jq -c '.tools=[]' <<<"$SF_TEST_PROFILE")
session="$tmp/limited.jsonl"
sf_test_session "$session"
SHELLFISH_MAX_TOOL_CALLS_PER_REQUEST=1 sf_test_run limited "$session" >"$stream" ||
  fail 'limited tool turn failed'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result")] as $results |
  ($results | length) == 2 and
  $results[0].exit_code == 127 and ($results[0].model_text | contains("not allowed")) and
  $results[1].exit_code == 126 and ($results[1].model_text | contains("limit"))
' <"$stream" >/dev/null || fail 'ordinary tool denials did not settle calls'
assert_canonical_session "$session"

# A failed append ends transcript mutation, including the usual durable error.
typeset break_hook="$tmp/break-session" broken="$tmp/broken.jsonl"
sf_test_hook "$break_hook" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
mv "$SHELLFISH_SESSION" "$SHELLFISH_SESSION.saved" || exit
mkdir "$SHELLFISH_SESSION"
ZSH
sf_test_bind_hooks user_prompt_submit "$break_hook"
sf_test_session "$broken"
integer broken_status=0
sf_test_run broken "$broken" >"$stream" 2>"$tmp/broken.stderr" || broken_status=$?
(( broken_status == 1 )) || fail 'turn continued after its session became unavailable'
[[ -d $broken && -z $(find "$broken" -mindepth 1 -print -quit) ]] ||
  fail 'turn mutated the unavailable session after its first write failure'
jq -es 'length == 1 and .[0].type == "session"' "$broken.saved" >/dev/null ||
  fail 'write failure changed the previously durable prefix'

# A provider receives every .env value; exported values win.
sf_test_frozen_profile
typeset env_provider="$tmp/env-provider/run" env_session="$tmp/env.jsonl"
mkdir -p "${env_provider:h}"
typeset env_config="$SHELLFISH_DIR"
mkdir -p "$env_config"
print -rl -- FILE_SECRET=file-value EXPORTED_SECRET=file-value >"$env_config/.env"
cat >"$env_provider" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
jq -cn --arg text "${FILE_SECRET-unset} ${EXPORTED_SECRET-unset}" \
  '{type:"assistant",stop:"end",content:[{type:"text",text:$text}]}'
ZSH
chmod +x "$env_provider"
SF_TEST_MODEL=$(jq -c --arg provider "${env_provider:h}" '.provider=$provider' <<<"$SF_TEST_MODEL")
export EXPORTED_SECRET=exported-value
sf_test_session "$env_session"
sf_test_run env "$env_session" >"$stream" || fail 'provider environment turn failed'
jq -eRn '[inputs | fromjson | select(.type == "assistant") | .content[0].text] ==
  ["file-value exported-value"]' <"$stream" >/dev/null ||
  fail 'provider did not receive layered environment values'
unset EXPORTED_SECRET

# The client races review hooks. Only the turn owner persists their output.
sf_test_frozen_profile
SF_TEST_PROFILE=$(jq -c '.sandbox.enabled=true' <<<"$SF_TEST_PROFILE")
typeset review_hook="$tmp/reviewer"
sf_test_hook "$review_hook" '{"on":"permission_request"}' <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
jq -cn --argjson pid $$ '{state_update:[{name:"review/started",value:$pid}]}' >&3
sleep "${REVIEW_DELAY:-0}"
[[ ${REVIEW_FAIL:-0} != 1 ]] || exit 3
[[ -n $REVIEW_ACTION ]] || exit 0
jq -cn --arg action "$REVIEW_ACTION" '{action:$action,reason:"review verdict"}' >&3
ZSH
sf_test_bind_hooks permission_request "$review_hook"
sf_test_shell_tool '.sandbox=true | .allow_sandbox_bypass=true'
sf_test_session "$tmp/review-header.jsonl"
python3 - "$ROOT" "$tmp" <<'PY'
import json
import os
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

root, tmp = map(Path, sys.argv[1:])
header = (tmp / "review-header.jsonl").read_bytes()
runs = []


class Review:
    def __init__(self, name, action="allow", delay=0, fail=False):
        session = tmp / (name + ".jsonl")
        session.write_bytes(header)
        self.process = subprocess.Popen(
            [str(root / "bin/shellfish"), "run", "--jsonl", "--session", str(session)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=dict(os.environ, REVIEW_ACTION=action, REVIEW_DELAY=str(delay),
                     REVIEW_FAIL=str(int(fail)), SF_TEST_PROVIDER_TOOL_CALL="1",
                     SF_TEST_PROVIDER_TOOL_BYPASS="true",
                     SF_TEST_PROVIDER_TOOL_COMMAND="print -rn -- executed"),
        )
        runs.append(self)
        self.buffer = b""
        self.events = []
        self.send({"type": "user", "content": [{"type": "text", "text": name}]})
        self.request = self.until("_tool_permission_request")
        assert not any(e.get("name") == "review/started" for e in self.events)

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()

    def answer(self, decision):
        self.send({"type": "_tool_permission_response", "id": self.request["id"],
                   "decision": decision})

    def until(self, kind, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                assert remaining > 0 and select.select([self.process.stdout], [], [], remaining)[0], kind
                data = os.read(self.process.stdout.fileno(), 65536)
                assert data, (kind, self.process.poll(), self.process.stderr.read())
                self.buffer += data
            line, self.buffer = self.buffer.split(b"\n", 1)
            event = json.loads(line)
            self.events.append(event)
            if event["type"] == kind:
                return event

    def finish(self, exit_code):
        result = self.until("tool_result")
        assert result["exit_code"] == exit_code, result
        self.process.stdin.close()
        assert self.process.wait(timeout=5) == 0, self.process.stderr.read()
        return result


try:
    early = Review("user-first", action="deny", delay=30)
    started = early.until("state_update")
    early.answer("approve")
    start = time.monotonic()
    early.finish(0)
    assert time.monotonic() - start < 3
    assert not any(e["type"] == "hook_result" for e in early.events)
    try:
        os.kill(started["value"], 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("cancelled reviewer is still alive")

    override = Review("override-denial", action="deny")
    verdict = override.until("_tool_permission_review")
    assert verdict["decision"] == "deny" and verdict["timeout"] == 10, verdict
    override.answer("approve")
    override.finish(0)

    for name, action, fail in [("defer", "", False), ("failure", "allow", True)]:
        review = Review(name, action=action, fail=fail)
        verdict = review.until("_tool_permission_review")
        assert verdict["decision"] == "" and verdict["timeout"] == 0, verdict
        review.answer("deny")
        review.finish(126)

    held = Review("held")
    held.until("_tool_permission_review")
    held.answer("hold")
    held_at = time.monotonic()
    automatic = []
    for action, exit_code in [("allow", 0), ("deny", 126)]:
        review = Review("auto-" + action, action=action)
        verdict = review.until("_tool_permission_review")
        assert verdict["timeout"] == 10, verdict
        automatic.append((review, exit_code, time.monotonic()))
    for review, exit_code, start in automatic:
        review.finish(exit_code)
        assert time.monotonic() - start >= 9.8, "review applied without its grace period"
    while time.monotonic() - held_at < 10.5:
        time.sleep(0.05)
    assert held.process.poll() is None, "taking control did not disable automatic approval"
    held.answer("deny")
    held.finish(126)
finally:
    for review in runs:
        if review.process.poll() is None:
            review.process.send_signal(signal.SIGUSR1)
            review.process.wait(timeout=5)
PY

print -r -- ok
