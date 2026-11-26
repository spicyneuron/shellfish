#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp run-tool-cancel-contract
sf_test_frozen_profile

# Start a two-call tool turn, then interrupt it once the marker appears.
interrupt() {
  local session=$1 stream=$2 marker=$3 command=$4
  integer run_status=0
  sf_test_session "$session"
  jq -cn --arg text cancel '{type:"user",content:[{type:"text",text:$text}]}' |
    SF_TEST_PROVIDER_TOOL_CALL=1 SF_TEST_PROVIDER_TOOL_COUNT=2 \
    SF_TEST_PROVIDER_TOOL_COMMAND="$command" \
    "$ROOT/bin/shellfish" run --jsonl --session "$session" >"$stream" &
  sf_test_wait test -e "$marker" || fail 'interruption point was not reached'
  kill -TERM $! || fail 'tool turn ended before interruption'
  wait $! || run_status=$?
  (( run_status == 143 )) || fail 'interrupted tool turn returned the wrong status'
}

# Interrupting an active tool settles it and cancels later calls from the
# already-durable assistant response without starting more lifecycle hooks.
typeset session="$tmp/tool-cancel.jsonl" stream="$tmp/tool-cancel.stream"
typeset marker="$tmp/tool-active" finished="$tmp/tool-finished"
typeset command=": >${(q)marker}; sleep 30; : >${(q)finished}"
interrupt "$session" "$stream" "$marker" "$command"
[[ ! -e $finished ]] || fail 'interrupted tool ran to completion'
jq -eRn --arg command "$command" '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "tool_result") |
    {id,input,exit_code,model_content})) == [
      {id:"call_1",input:{command:$command},exit_code:126,
       model_content:[{type:"text",text:"tool call interrupted"}]},
      {id:"call_2",input:{command:$command},exit_code:126,
       model_content:[{type:"text",text:"tool call cancelled"}]}
    ] and
  $events[-1] == {type:"error",section:2,user_text:"Turn interrupted."}
' <"$stream" >/dev/null || fail 'tool interruption did not settle pending calls'
assert_canonical_session "$session"

# An interrupted tool renders its template with the reason as stderr.
typeset profile=$SF_TEST_PROFILE
sf_test_shell_tool '.user_text = "Stopped\n${output.stderr}"'
session="$tmp/partial-cancel.jsonl" stream="$tmp/partial-cancel.stream"
rm -f "$marker"
interrupt "$session" "$stream" "$marker" "$command"
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result") | .user_text] ==
    ["Stopped\ntool call interrupted", "Stopped\ntool call cancelled"]
' <"$stream" >/dev/null || fail 'interrupted tool did not render its reason'
assert_canonical_session "$session"
SF_TEST_PROFILE=$profile

# A tool that finished keeps its real result when a post hook is interrupted.
typeset post="$tmp/post" posted="$tmp/post-active"
print -rl -- '#!/usr/bin/env zsh' ": >${(q)posted}; sleep 30" | sf_test_hook "$post"
sf_test_bind_hooks post_tool_use "$post"
session="$tmp/post-cancel.jsonl" stream="$tmp/post-cancel.stream"
interrupt "$session" "$stream" "$posted" 'print -rn -- ran'
jq -eRn '
  [inputs | fromjson | select(.type == "tool_result") | [.id,.exit_code]] ==
    [["call_1",0],["call_2",126]]
' <"$stream" >/dev/null || fail 'interrupted post hook lost the known tool result'
assert_canonical_session "$session"

# Opening a session whose turn never finished settles its calls the same way.
typeset recovered="$tmp/recovered.jsonl" recovered_stream="$tmp/recovered.stream"
sf_test_session "$recovered"
jq -cn '{type:"user",section:1,content:[{type:"text",text:"interrupted"}]}' >>"$recovered"
jq -cn '{type:"assistant",section:2,stop:"tool_calls",
  content:[{type:"tool_call",id:"call_1",name:"shell",input:{command:"true"}}]}' >>"$recovered"
jq -cn '{type:"user",content:[{type:"text",text:"next"}]}' |
  "$ROOT/bin/shellfish" run --jsonl --session "$recovered" >"$recovered_stream" ||
  fail 'recovery run failed'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[0] | .type == "tool_result" and .id == "call_1" and .exit_code == 126 and
    (has("executable") | not) and .model_content[0].text == "tool call outcome unknown") and
  ($events[1] == {type:"error",section:2,user_text:"Turn interrupted."})
' <"$recovered_stream" >/dev/null || fail 'recovery did not settle through the tool owner'
assert_canonical_session "$recovered"

# TERM during capture must win over an already-written child exit status.
(
  sf_test_source libexec/run/component.zsh
  interrupt_after_exit() {
    integer polls=0
    while kill -0 "$1" 2>/dev/null && (( polls++ < 100 )); do sleep 0.01; done
    ! kill -0 "$1" 2>/dev/null || fail 'isolation wrapper did not exit'
    kill -TERM $sysparams[pid]
  }
  integer code
  for code in 0 130; do
    mkdir "$tmp/late-$code"
    sf_run_component_begin "$recovered" '{}'
    sf_run_component_execute "$tmp/late-$code" "$tmp" /dev/null 128 128 \
      interrupt_after_exit zsh -f -c 'print -r -u3 -- "$PPID"; exit "$1"' -- "$code" ||
      fail "$SF_ERROR"
    assert_equal interrupted "$reply[1]"
    assert_equal 143 "$reply[2]"
  done
  mkdir "$tmp/exit-130"
  sf_run_component_begin "$recovered" '{}'
  sf_run_component_execute "$tmp/exit-130" "$tmp" /dev/null 128 128 : \
    zsh -f -c 'exit 130' || fail "$SF_ERROR"
  assert_equal ok "$reply[1]"
  assert_equal 130 "$reply[2]"
)

# Signals while awaiting permission settle every call without running a tool.
SF_TEST_PROFILE=$(jq -c '.sandbox.enabled=true' <<<"$profile")
session="$tmp/permission-cancel.jsonl"
sf_test_session "$session"
python3 - "$ROOT" "$session" "$tmp/permission-ran" <<'PY'
import json
import os
import shlex
import signal
import subprocess
import sys
from pathlib import Path

root, path, marker = map(Path, sys.argv[1:])
header = path.read_text()
for sig in (signal.SIGINT, signal.SIGUSR1, signal.SIGHUP, signal.SIGTERM):
    path.write_text(header)
    process = subprocess.Popen(
        [str(root / "bin/shellfish"), "run", "--jsonl", "--session", str(path)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True,
        env=dict(os.environ, SF_TEST_PROVIDER_TOOL_CALL="1",
                 SF_TEST_PROVIDER_TOOL_COUNT="3", SF_TEST_PROVIDER_TOOL_BYPASS="true",
                 SF_TEST_PROVIDER_TOOL_COMMAND=f"touch {shlex.quote(str(marker))}"),
    )
    try:
        process.stdin.write(json.dumps({"type": "user", "content": [
            {"type": "text", "text": "cancel permission"}]}) + "\n")
        process.stdin.flush()
        events = []
        for line in process.stdout:
            events.append(json.loads(line))
            if events[-1]["type"] == "_tool_permission_request":
                break
        else:
            raise AssertionError("turn did not request permission")
        process.send_signal(sig)
        output, error = process.communicate(timeout=5)
        code = 130 if sig in (signal.SIGINT, signal.SIGUSR1) else 128 + sig
        assert process.returncode == code, (sig, process.returncode, error)
        events.extend(json.loads(line) for line in output.splitlines())
        records = [json.loads(line) for line in path.read_text().splitlines()]
        assert [r["type"] for r in records] == [
            "session", "user", "assistant", "tool_result", "tool_result", "tool_result", "error"
        ], (sig, records, error)
        results = records[3:6]
        assert all(r["section"] == 2 for r in results)
        assert [(r["id"], r["exit_code"]) for r in results] == [
            ("call_1", 126), ("call_2", 126), ("call_3", 126)], (sig, results, error)
        assert [r.get("sandbox_access") for r in results] == ["cancelled", None, None]
        assert all(r["model_content"] == [{"type": "text", "text": "tool call cancelled"}] for r in results)
        assert records[-1] == {"type": "error", "section": 2, "user_text":
                               "Cancelled." if code == 130 else "Turn interrupted."}
        assert records[1:] == [e for e in events if not e["type"].startswith("_")]
        assert not marker.exists(), "cancelled permission ran a tool"
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
PY
assert_canonical_session "$session"

print -r -- ok
