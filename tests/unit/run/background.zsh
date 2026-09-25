#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"

sf_test_tmp run-background
sf_test_frozen_profile
local session="$tmp/session.jsonl" ack="$tmp/ack" err="$tmp/err"
sf_test_session "$session"

"$ROOT/bin/shellfish" run --background --jsonl --session "$session" \
  </dev/null >"$ack" 2>"$err" && fail '--background --jsonl unexpectedly succeeded'
[[ ! -s $ack ]] || fail '--background --jsonl wrote stdout'
grep -q 'cannot be combined with --jsonl' "$err" || fail 'missing --jsonl conflict diagnostic'

if [[ $OSTYPE != darwin* && $OSTYPE != linux* ]] ||
    { [[ $OSTYPE == linux* ]] && (( ! $+commands[setsid] )); }; then
  "$ROOT/bin/shellfish" run --background --session "$session" hello >"$ack" 2>"$err" &&
    fail 'background launch unexpectedly succeeded without a launcher'
  grep -q 'requires macOS /usr/bin/script or Linux setsid' "$err" ||
    fail 'missing unsupported-platform diagnostic'
  exit 0
fi

"$ROOT/bin/shellfish" run --background --session "$session" delay >"$ack" 2>"$err" ||
  fail "background launch failed: $(cat "$err")"
assert_equal "$session" "$(cat "$ack")"
[[ ! -s $err ]] || fail 'background launch wrote stderr'
jq -e -s 'all(.[]; .type != "assistant")' "$session" >/dev/null ||
  fail 'launch did not return before delayed backend finished'

integer waited=0
until jq -e -s 'any(.[]; .type == "assistant" and .stop == "end")' "$session" >/dev/null; do
  (( waited++ < 100 )) || fail 'background turn did not finish'
  sleep 0.1
done
assert_canonical_session "$session" end

local cancelled="$tmp/cancelled.jsonl"
sf_test_session "$cancelled"
python3 - "$ROOT/bin/shellfish" "$cancelled" <<'PY'
import os
import signal
import subprocess
import sys

run, session = sys.argv[1:]
process = subprocess.Popen(
    ["/bin/zsh", "-c", '"$@" || exit; sleep 10', "--", run, "run",
     "--background", "--session", session, "survive delay"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    start_new_session=True,
)
ack = process.stdout.readline()
assert ack.strip() == session, (ack, process.stderr.read())
assert process.poll() is None, "initiating group exited before cancellation"
os.killpg(process.pid, signal.SIGTERM)
assert process.wait(timeout=15) != 0, "initiating group ignored cancellation"
PY

waited=0
until jq -e -s 'any(.[]; .type == "assistant" and .stop == "end")' "$cancelled" >/dev/null; do
  (( waited++ < 100 )) || fail 'detached turn died with invoking process group'
  sleep 0.1
done
assert_canonical_session "$cancelled" end
