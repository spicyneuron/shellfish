#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_tmp exec-command-signals

typeset config="$tmp/config.jsonc"
cat >"$config" <<EOF
{
  "default_profile": "exec",
  "backends": {"fixture": {"adapter": "$ROOT/tests/fixtures/backend"}},
  "harnesses": {
    "machine": {
      "system": [], "tools": [], "sandbox": true,
      "session_start": [], "user_prompt_submit": [], "permission_request": [],
      "pre_tool_use": [], "post_tool_use": [], "stop": [],
      "max_requests_per_turn": 8, "max_tool_calls_per_request": 16,
      "max_capture_bytes": 65536
    }
  },
  "profiles": {
    "exec": {
      "backend": "fixture", "harness": "machine",
      "request": {"model": "test-model"}
    }
  }
}
EOF
export XDG_STATE_HOME="$tmp/state"
typeset entry="$ROOT/bin/shellfish"

# Interrupting a creation hook leaves the created prefix unlocked. Reopening the
# session does not retry the hook.
typeset interrupt_hook="$tmp/interrupt-start" interrupt_marker="$tmp/interrupt-started"
cat >"$interrupt_hook" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 1 && $1 == session_start ]] || exit 1
print -r -- started >>"$INTERRUPT_MARKER"
trap 'exit 143' TERM
zmodload zsh/zselect
while true; do zselect -t 100; done
ZSH
chmod +x "$interrupt_hook"
typeset interrupt_config="$tmp/interrupt-start.jsonc"
jq --arg hook "$interrupt_hook" '.harnesses.machine.session_start=[$hook]' \
  "$config" >"$interrupt_config"
typeset interrupt_session="$tmp/interrupted-start.jsonl"
typeset interrupt_output="$tmp/interrupted-start.out"
unsetopt BG_NICE
INTERRUPT_MARKER="$interrupt_marker" zsh -f "$entry" exec --config "$interrupt_config" \
  --session "$interrupt_session" ignored >"$interrupt_output" 2>&1 &
typeset interrupt_pid=$!
setopt BG_NICE
integer interrupt_waited=0
while (( interrupt_waited < 50 )) && [[ ! -s $interrupt_marker ]]; do
  sleep 0.1
  (( interrupt_waited += 1 ))
done
(( interrupt_waited < 50 )) || fail 'session_start hook did not begin'
kill -TERM "$interrupt_pid" || fail 'session_start hook ended before interruption'
integer interrupt_status=0
wait "$interrupt_pid" || interrupt_status=$?
(( interrupt_status == 143 )) ||
  fail "interrupted session_start reported status $interrupt_status instead of 143: $(<"$interrupt_output")"
[[ ! -e "$interrupt_session.lock" ]] || fail 'interrupted session_start left the session locked'
[[ ! -e $interrupt_session ]] || fail 'interrupted session_start created a session'
(( $(wc -l <"$interrupt_marker") == 1 )) || fail 'session_start ran more than once'

# A signalled run stops exec, closes the interrupted turn on disk, and
# reports the signal rather than an ordinary failure.
typeset cancel_session="$tmp/cancel.jsonl" cancel_output="$tmp/cancel.out"
SF_TEST_BACKEND_DELAY=0.3 zsh -f "$entry" exec --jsonl --config "$config" \
  --session "$cancel_session" \
  < <(print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"alpha beta gamma delta epsilon zeta eta theta"}]}') \
  >"$cancel_output" 2>&1 &
typeset cancel_pid=$!
# Signal a turn that has demonstrably started, rather than one a loaded machine
# may not have reached yet.
integer waited=0
while (( waited < 50 )) && ! grep -q '_assistant_delta' "$cancel_output" 2>/dev/null; do
  sleep 0.1
  (( waited += 1 ))
done
(( waited < 50 )) || fail 'exec never started streaming a turn to cancel'
kill -TERM "$cancel_pid" || fail 'turn ended before it could be cancelled'
integer cancel_status=0
wait "$cancel_pid" || cancel_status=$?
(( cancel_status == 143 )) || fail 'signalled exec did not report the signal'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-1] | .role == "assistant" and .stop == "end")
' <"$cancel_output" >/dev/null || fail 'signalled exec did not close the interrupted turn'
assert_session_unlocked "$cancel_session"

# A turn that never finished is repaired when the session is next opened, and
# the repair is announced before the new turn, since it is as durable as any
# record the turn itself commits.
typeset recovered_session="$tmp/recovered.jsonl"
SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" exec --config "$config" \
  --session "$recovered_session" seed >/dev/null || fail 'recovery seed failed'
print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"interrupted"}]}' \
  >>"$recovered_session"
typeset jsonl
jsonl=$(print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"next"}]}' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" exec --jsonl --config "$config" \
    --session "$recovered_session") || fail 'recovery run failed'
print -r -- "$jsonl" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events[0] | .role == "assistant" and .stop == "end") and
  ($events[1] | .role == "user")
' >/dev/null || fail 'exec did not announce the recovered record'
