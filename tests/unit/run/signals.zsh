#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
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

# Cancellation stops context discovery.
typeset model_backend="$tmp/model-backend" model_ready="$tmp/model-ready"
typeset model_stopped="$tmp/model-stopped" model_config="$tmp/model.jsonc"
mkdir "$model_backend"
cat >"$model_backend/manifest.json" <<'JSON'
{"endpoint":"https://example.invalid/v1/messages","environment":[]}
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
  zsh -f "$entry" run --config "$model_config" --session-out "$model_session" prompt \
  >"$model_output" 2>&1 &
typeset model_pid=$!
integer model_waited=0
while (( model_waited < 50 )) && [[ ! -s $model_ready ]]; do
  sleep 0.1
  (( model_waited += 1 ))
done
(( model_waited < 50 )) || fail 'model metadata lookup did not begin'
kill -USR1 "$model_pid" || fail 'model metadata lookup ended before cancellation'
integer model_status=0
wait "$model_pid" || model_status=$?
(( model_status == 130 )) || fail 'cancelled model metadata lookup reported the wrong status'
[[ -s $model_stopped ]] || fail 'cancelled model metadata adapter was not stopped cleanly'
jq -e -s '.[-1] == {type:"error",user_text:"Cancelled."}' "$model_session" >/dev/null ||
  fail 'cancelled model metadata lookup did not persist its outcome'

# SIGINT persists partial assistant content.
typeset cancel_session="$tmp/cancel.jsonl" cancel_output="$tmp/cancel.out"
SF_TEST_BACKEND_DELAY=0.3 zsh -f "$entry" run --jsonl --config "$config" \
  --session-out "$cancel_session" \
  < <(print -r -- '{"type":"user","content":[{"type":"text","text":"alpha beta gamma delta epsilon zeta eta theta"}]}') \
  >"$cancel_output" 2>&1 &
typeset cancel_pid=$!
# Wait for streaming before signaling.
integer waited=0
while (( waited < 50 )) && ! grep -q '_assistant_message_delta' "$cancel_output" 2>/dev/null; do
  sleep 0.1
  (( waited += 1 ))
done
(( waited < 50 )) || fail 'exec never started streaming a turn to cancel'
kill -INT "$cancel_pid" || fail 'turn ended before it could be cancelled'
integer cancel_status=0
wait "$cancel_pid" || cancel_status=$?
(( cancel_status == 130 )) || fail 'cancelled exec did not report the signal'
jq -eRn '
  [inputs | fromjson] as $events |
  ($events[-2] | .type == "assistant" and .stop == "cancelled" and
    (.content | any(.type == "text" and .text != "")))
  and $events[-1] == {type:"error",user_text:"Cancelled."}
' <"$cancel_output" >/dev/null || fail 'cancelled exec did not persist partial content'

# Cancellation preserves reasoning metadata.
typeset cancel_backend="$tmp/cancel-backend" cancel_backend_marker="$tmp/tool-input"
typeset cancel_backend_pid_file="$tmp/tool-input-child"
mkdir "$cancel_backend"
cp "$ROOT/tests/fixtures/backend/manifest.json" "$cancel_backend/manifest.json"
cat >"$cancel_backend/run" <<'ZSH'
#!/usr/bin/env zsh
request=$(cat)
prompt=$(jq -r '.messages[-1].content[0].text' <<<"$request")
if [[ -n ${CANCEL_BACKEND_PID_FILE-} ]]; then
  (sleep 30 & print -r -- $! >"$CANCEL_BACKEND_PID_FILE"; wait) &
fi
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
  --session-out "$reasoning_session" \
  < <(print -r -- '{"type":"user","content":[{"type":"text","text":"reasoning"}]}') \
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
  .[-2] == {type:"assistant",stop:"cancelled",content:[{
    type:"reasoning",text:"partial thought",
    opaque:{id:"reasoning_1",encrypted_content:"secret"}
  }]} and .[-1] == {type:"error",user_text:"Turn interrupted."}
' "$reasoning_session" >/dev/null || fail 'cancelled reasoning was not recovered'

# Partial tool input remains transient.
typeset tool_input_session="$tmp/tool-input-cancel.jsonl" tool_input_output="$tmp/tool-input-cancel.out"
CANCEL_BACKEND_MARKER="$cancel_backend_marker" CANCEL_BACKEND_PID_FILE="$cancel_backend_pid_file" \
  zsh -f "$entry" run --jsonl \
  --config "$cancel_backend_config" --session-out "$tool_input_session" \
  < <(print -r -- '{"type":"user","content":[{"type":"text","text":"tool input"}]}') \
  >"$tool_input_output" 2>&1 &
typeset tool_input_pid=$!
waited=0
while (( waited < 50 )) &&
    [[ ! -s $cancel_backend_marker || ! -s $cancel_backend_pid_file ]]; do
  sleep 0.1
  (( waited += 1 ))
done
(( waited < 50 )) || fail 'backend never started tool input to cancel'
sleep 0.1
kill -TERM "$tool_input_pid" || fail 'tool-input turn ended before cancellation'
integer tool_input_status=0
wait "$tool_input_pid" || tool_input_status=$?
(( tool_input_status == 143 )) || fail 'cancelled tool-input turn did not report the signal'
integer cancel_child_pid cancel_child_polls=0
cancel_child_pid=$(<"$cancel_backend_pid_file")
while (( cancel_child_polls++ < 50 )) && kill -0 "$cancel_child_pid" 2>/dev/null; do
  sleep 0.01
done
! kill -0 "$cancel_child_pid" 2>/dev/null || fail 'cancelled backend grandchild survived'
jq -e -s '
  .[-2] == {type:"user",content:[{type:"text",text:"tool input"}]} and
  .[-1] == {type:"error",user_text:"Turn interrupted."} and
  ([.[] | .content[]? | select(.type == "tool_call")] | length) == 0
' "$tool_input_session" >/dev/null || fail 'cancelled tool input became durable intent'

# Interrupted sessions accept another turn.
typeset recovered_session="$tmp/recovered.jsonl"
SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --config "$config" \
  --session-out "$recovered_session" seed >/dev/null || fail 'recovery seed failed'
print -r -- \
  '{"type":"user","content":[{"type":"text","text":"interrupted"}]}' \
  >>"$recovered_session"
typeset jsonl
jsonl=$(print -r -- \
  '{"type":"user","content":[{"type":"text","text":"next"}]}' |
  SF_TEST_BACKEND_DELAY=0 zsh -f "$entry" run --jsonl --config "$config" \
    --session "$recovered_session") || fail 'recovery run failed'
print -r -- "$jsonl" | jq -eRn '
  [inputs | fromjson] as $events |
  $events[0] == {type:"error",user_text:"Turn interrupted."} and
  ($events[1] | .type == "user")
' >/dev/null || fail 'exec did not start after an unfinished turn'

# An incomplete physical tail is an error and is never repaired in place.
typeset incomplete="$tmp/incomplete.jsonl" incomplete_before="$tmp/incomplete.before"
cp "$recovered_session" "$incomplete"
print -rn -- '{"type":"user"' >>"$incomplete"
cp "$incomplete" "$incomplete_before"
integer incomplete_status=0
print -r -- '{"type":"user","content":[{"type":"text","text":"next"}]}' |
  zsh -f "$entry" run --jsonl --session "$incomplete" \
  >/dev/null 2>"$tmp/incomplete.stderr" || incomplete_status=$?
(( incomplete_status == 1 )) || fail 'run accepted an incomplete session tail'
cmp -s "$incomplete_before" "$incomplete" || fail 'run repaired an incomplete session tail'
