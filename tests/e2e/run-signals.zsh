#!/usr/bin/env zsh

source "${0:A:h:h}/_helpers.zsh"
sf_test_tmp exec-command-signals

typeset config="$tmp/shellfish.jsonc"
cat >"$config" <<EOF
{
  "default_profile": "exec",
  "backends": {"fixture": {"adapter": "$ROOT/tests/fixtures/backend"}},
  "harnesses": {
    "machine": {
      "tools": [], "sandbox": true,
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

# Interrupting a session_start script creates no session. Reopening the
# session does not retry the script.
typeset interrupt_script="$tmp/interrupt-start" interrupt_marker="$tmp/interrupt-started"
cat >"$interrupt_script" <<'ZSH'
#!/usr/bin/env zsh
[[ $# == 1 && $1 == session_start ]] || exit 1
print -r -- started >>"$INTERRUPT_MARKER"
trap 'exit 143' TERM
zmodload zsh/zselect
while true; do zselect -t 100; done
ZSH
chmod +x "$interrupt_script"
typeset interrupt_config="$tmp/interrupt-start.jsonc"
jq --arg script "$interrupt_script" '.harnesses.machine.session_start=[$script]' \
  "$config" >"$interrupt_config"
typeset interrupt_session="$tmp/interrupted-start.jsonl"
typeset interrupt_output="$tmp/interrupted-start.out"
unsetopt BG_NICE
INTERRUPT_MARKER="$interrupt_marker" zsh -f "$entry" run --config "$interrupt_config" \
  --session "$interrupt_session" ignored >"$interrupt_output" 2>&1 &
typeset interrupt_pid=$!
setopt BG_NICE
integer interrupt_waited=0
while (( interrupt_waited < 50 )) && [[ ! -s $interrupt_marker ]]; do
  sleep 0.1
  (( interrupt_waited += 1 ))
done
(( interrupt_waited < 50 )) || fail 'session_start script did not begin'
kill -TERM "$interrupt_pid" || fail 'session_start script ended before interruption'
integer interrupt_status=0
wait "$interrupt_pid" || interrupt_status=$?
(( interrupt_status == 143 )) ||
  fail "interrupted session_start reported status $interrupt_status instead of 143: $(<"$interrupt_output")"
[[ ! -e $interrupt_session ]] || fail 'interrupted session_start created a session'
(( $(wc -l <"$interrupt_marker") == 1 )) || fail 'session_start ran more than once'

# Cancelling model metadata lookup stops the adapter and ends the turn.
typeset model_backend="$tmp/model-backend" model_ready="$tmp/model-ready"
typeset model_stopped="$tmp/model-stopped" model_config="$tmp/model.jsonc"
mkdir "$model_backend"
cat >"$model_backend/backend.json" <<'JSON'
{"endpoint":"https://example.invalid/v1/messages","api_key_env":""}
JSON
cat >"$model_backend/run" <<'ZSH'
#!/usr/bin/env zsh
exit 1
ZSH
cat >"$model_backend/context_window" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -- ready >"$MODEL_READY"
trap 'print -r -- stopped >"$MODEL_STOPPED"; exit 143' TERM
while true; do sleep 0.1; done
ZSH
chmod +x "$model_backend/run" "$model_backend/context_window"
jq --arg adapter "$model_backend" '.backends.fixture.adapter=$adapter' \
  "$config" >"$model_config"
typeset model_session="$tmp/model-cancel.jsonl" model_output="$tmp/model-cancel.out"
MODEL_READY="$model_ready" MODEL_STOPPED="$model_stopped" \
  zsh -f "$entry" run --config "$model_config" --session "$model_session" prompt \
  >"$model_output" 2>&1 &
typeset model_pid=$!
integer model_waited=0
while (( model_waited < 50 )) && [[ ! -s $model_ready ]]; do
  sleep 0.1
  (( model_waited += 1 ))
done
(( model_waited < 50 )) || fail 'model metadata lookup did not begin'
kill -TERM "$model_pid" || fail 'model metadata lookup ended before interruption'
integer model_status=0
wait "$model_pid" || model_status=$?
(( model_status == 143 )) || fail 'interrupted model metadata lookup reported the wrong status'
[[ -s $model_stopped ]] || fail 'interrupted model metadata adapter was not stopped'

# A signalled run stops exec, closes the interrupted turn on disk, and
# reports the signal rather than an ordinary failure.
typeset cancel_session="$tmp/cancel.jsonl" cancel_output="$tmp/cancel.out"
SF_TEST_BACKEND_DELAY=0.3 zsh -f "$entry" run --jsonl --config "$config" \
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
  ($events[-1] | .role == "assistant" and .stop == "length" and
    (.content | any(.type == "text" and .text != "")))
' <"$cancel_output" >/dev/null || fail 'signalled exec did not close the interrupted turn'

# Reasoning metadata received before cancellation remains available to the next
# provider request when visible reasoning is recovered.
typeset cancel_backend="$tmp/cancel-backend" cancel_backend_marker="$tmp/tool-input"
mkdir "$cancel_backend"
cp "$ROOT/tests/fixtures/backend/backend.json" "$cancel_backend/backend.json"
cat >"$cancel_backend/run" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
prompt=$(jq -r '.messages[-1].content[0].text' <<<"$request")
if [[ $prompt == reasoning ]]; then
  print -r -- '{"type":"_assistant_reasoning_opaque","index":0,"opaque":{"id":"reasoning_1","encrypted_content":"secret"}}'
  print -r -- '{"type":"_assistant_reasoning_delta","index":0,"text":"partial thought"}'
else
  print -r -- '{"type":"_assistant_tool_call_delta","index":0,"id":"call_1","name":"shell","input":"{}"}'
  print -r -- ready >"$CANCEL_BACKEND_MARKER"
fi
trap 'exit 143' TERM
while true; do sleep 1; done
ZSH
chmod +x "$cancel_backend/run"
typeset cancel_backend_config="$tmp/cancel-backend.jsonc"
jq --arg adapter "$cancel_backend" '.backends.fixture.adapter=$adapter' \
  "$config" >"$cancel_backend_config"

typeset reasoning_session="$tmp/reasoning-cancel.jsonl" reasoning_output="$tmp/reasoning-cancel.out"
zsh -f "$entry" run --jsonl --config "$cancel_backend_config" \
  --session "$reasoning_session" \
  < <(print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"reasoning"}]}') \
  >"$reasoning_output" 2>&1 &
typeset reasoning_pid=$!
waited=0
while (( waited < 50 )) && ! grep -q '_assistant_reasoning_delta' "$reasoning_output" 2>/dev/null; do
  sleep 0.1
  (( waited += 1 ))
done
(( waited < 50 )) || fail 'exec never streamed reasoning to cancel'
kill -TERM "$reasoning_pid" || fail 'reasoning turn ended before cancellation'
integer reasoning_status=0
wait "$reasoning_pid" || reasoning_status=$?
(( reasoning_status == 143 )) || fail 'cancelled reasoning turn did not report the signal'
jq -e -s '
  .[-1] == {type:"message",role:"assistant",stop:"length",content:[{
    type:"reasoning",text:"partial thought",
    opaque:{id:"reasoning_1",encrypted_content:"secret"}
  }]}
' "$reasoning_session" >/dev/null || fail 'cancelled reasoning was not recovered'

# A parseable tool-input prefix is not a completed provider response. Cancelling
# during it must not commit a call that a later turn could execute.
typeset tool_input_session="$tmp/tool-input-cancel.jsonl" tool_input_output="$tmp/tool-input-cancel.out"
CANCEL_BACKEND_MARKER="$cancel_backend_marker" zsh -f "$entry" run --jsonl \
  --config "$cancel_backend_config" --session "$tool_input_session" \
  < <(print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"tool input"}]}') \
  >"$tool_input_output" 2>&1 &
typeset tool_input_pid=$!
waited=0
while (( waited < 50 )) && [[ ! -s $cancel_backend_marker ]]; do
  sleep 0.1
  (( waited += 1 ))
done
(( waited < 50 )) || fail 'backend never started tool input to cancel'
sleep 0.1
kill -TERM "$tool_input_pid" || fail 'tool-input turn ended before cancellation'
integer tool_input_status=0
wait "$tool_input_pid" || tool_input_status=$?
(( tool_input_status == 143 )) || fail 'cancelled tool-input turn did not report the signal'
jq -e -s '
  .[-1] == {type:"message",role:"assistant",stop:"end",
    content:[{type:"text",text:"Turn interrupted."}]} and
  ([.[] | .content[]? | select(.type == "tool_call")] | length) == 0
' "$tool_input_session" >/dev/null || fail 'cancelled tool input became durable intent'

# A turn that never finished is repaired when the session is next opened, and
# the repair is announced before the new turn, since it is as durable as any
# record the turn itself commits.
typeset recovered_session="$tmp/recovered.jsonl"
SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --config "$config" \
  --session "$recovered_session" seed >/dev/null || fail 'recovery seed failed'
print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"interrupted"}]}' \
  >>"$recovered_session"
typeset jsonl
jsonl=$(print -r -- \
  '{"type":"message","role":"user","content":[{"type":"text","text":"next"}]}' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --jsonl --config "$config" \
    --session "$recovered_session") || fail 'recovery run failed'
print -r -- "$jsonl" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events[0] | .role == "assistant" and .stop == "end") and
  ($events[1] | .role == "user")
' >/dev/null || fail 'exec did not announce the recovered record'
