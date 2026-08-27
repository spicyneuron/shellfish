#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source session/main.zsh hooks.zsh

typeset stream
sf_test_tmp exec-stop-hooks
export XDG_STATE_HOME="$tmp/state"
export TEST_STATE_PATH="$tmp/turn-state"
typeset system_file="$tmp/system.md"
typeset request_capture="$tmp/request.json"
printf 'frozen system\n' >"$system_file"

sf_test_runtime "$system_file"
export SF_TEST_BACKEND_DELAY=0
export SF_TEST_BACKEND_REQUEST="$request_capture"

# A skipped stop commits attributed feedback and forces one more request. Its
# stderr uses attributed ephemeral notices, while stdout from the later
# status-0 invocation is discarded.
typeset stop_once="$tmp/stop-once"
cat >"$stop_once" <<'ZSH'
#!/usr/bin/env zsh
set -e
[[ $# == 2 && $1 == stop && $2 == <1-> ]]
[[ -n $SHELLFISH_SESSION_ID ]] || exit 2
[[ $SHELLFISH_TURN_ID == 1 ]] || exit 3
[[ $SHELLFISH_MODEL == test-model ]] || exit 4
[[ $PROJECT_DIR == "$PWD" ]] || exit 5
[[ ${PLUGIN_ROOT:A} == "${0:A:h}" ]] || exit 6
[[ ${PLUGIN_DATA:A} == "${XDG_STATE_HOME:A}/shellfish/hooks/stop/stop-once" ]] || exit 7
[[ ! -e $SHELLFISH_STATE_DIR/inherited ]] || exit 8
[[ -e $TEST_STATE_PATH ]] || print -rn -- "$SHELLFISH_STATE_DIR" >"$TEST_STATE_PATH"
input=$(cat)
print -r -- "$2|${input//$'\n'/\\n}" >>"$SHELLFISH_STATE_DIR/attempts"
if [[ ! -e $SHELLFISH_STATE_DIR/stopped ]]; then
  : >$SHELLFISH_STATE_DIR/stopped
  print -rn -- feedback
  print -rn -u2 -- first-local
  exit 10
fi
print -rn -- discarded
print -rn -u2 -- second-local
ZSH
chmod +x "$stop_once"
SF_TEST_RUNTIME=$(jq -c --arg hook "$stop_once" \
  '.harness.stop=[$hook]' <<<"$SF_TEST_RUNTIME")
typeset stop_session="$tmp/stop.jsonl"
sf_test_session "$stop_session"
sf_hooks_state_create
typeset inherited_state=$SHELLFISH_STATE_DIR
: >"$inherited_state/inherited"
stream=$(sf_test_turn original "$stop_session")
[[ -d $inherited_state && $SHELLFISH_STATE_DIR == "$inherited_state" ]]
[[ -s $TEST_STATE_PATH ]] || fail 'stop hook did not report its state directory'
typeset turn_state=$(<$TEST_STATE_PATH)
[[ ! -d $turn_state ]]
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "assistant")) | length) == 2 and
  ($events | map(select(.type == "context"))) ==
    [{type:"context",tag:"stop",hook:"stop-once",content:"feedback"}] and
  ($events | map(select(.type == "_hook_display") | [.event,(.hook|split("/")[-1]),.text])) ==
    [["stop","stop-once","first-local"],["stop","stop-once","second-local"]]
' >/dev/null
sf_hooks_state_cleanup
jq -e '
  .messages[-2].role == "assistant" and
  .messages[-1].role == "user" and
  .messages[-1].content[0].text ==
    "<stop hook=\"stop-once\">\nfeedback\n</stop>\n\n"
' "$request_capture" >/dev/null
jq -e -s '
  ([.[] | select(.type == "context")] | length) == 1 and
  ([.[] | select(.content? == "discarded")] | length) == 0
' "$stop_session" >/dev/null
sf_hooks_state_cleanup

# Stop stdin concatenates only the last assistant's text blocks and preserves
# trailing newlines. The attempt count starts at one.
typeset text_backend="$tmp/text-backend"
cat >"$text_backend" <<'ZSH'
#!/usr/bin/env zsh
cat >/dev/null
print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"first\n"},{"type":"reasoning","text":"omit"},{"type":"text","text":"second\n"}]}'
ZSH
chmod +x "$text_backend"
typeset text_stop="$tmp/text-stop"
cat >"$text_stop" <<'ZSH'
#!/usr/bin/env zsh
set -e
[[ $# == 2 && $1 == stop && $2 == 1 ]]
cmp -s /dev/stdin "$SHELLFISH_STATE_DIR/expected"
ZSH
chmod +x "$text_stop"
SF_TEST_RUNTIME=$(jq -c --arg hook "$text_stop" --arg backend "$text_backend" '
  .harness.stop=[$hook] | .backend.command=$backend
' <<<"$SF_TEST_RUNTIME")
typeset text_session="$tmp/stop-text.jsonl"
sf_test_session "$text_session"
sf_hooks_state_create
printf 'first\nsecond\n' >"$SHELLFISH_STATE_DIR/expected"
stream=$(sf_test_turn text "$text_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | any(.type == "message" and .role == "assistant"))
' >/dev/null
sf_hooks_state_cleanup
SF_TEST_RUNTIME=$(jq -c --arg backend "$ROOT/tests/fixtures/backend/run" \
  '.backend.command=$backend' <<<"$SF_TEST_RUNTIME")

# Continuation feedback may lead to tools; the ordinary tool loop remains in
# the same bounded turn and stop runs again after the final assistant.
typeset tool_stop="$tmp/stop-feedback"
cat >"$tool_stop" <<'ZSH'
#!/usr/bin/env zsh
if [[ ! -e $SHELLFISH_STATE_DIR/tool-feedback ]]; then
  : >$SHELLFISH_STATE_DIR/tool-feedback
  print -rn -- 'use a tool'
  exit 10
fi
ZSH
chmod +x "$tool_stop"
SF_TEST_RUNTIME=$(jq -c --arg hook "$tool_stop" \
  '.harness.stop=[$hook]' <<<"$SF_TEST_RUNTIME")
typeset tool_stop_session="$tmp/stop-tool.jsonl"
sf_test_session "$tool_stop_session"
stream=$(sf_test_turn original "$tool_stop_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.role == "assistant") | .stop)) ==
    ["end","tool_calls","end"] and
  ($events | map(select(.role == "tool_result") | .exit_code)) == [0]
' >/dev/null

# Repeated skipped completion is bounded by the existing provider request
# limit. Exhaustion keeps the committed assistant and feedback, then appends a
# canonical cancellation record to restore an await-user state.
typeset stop_always="$tmp/stop-always"
cat >"$stop_always" <<'ZSH'
#!/usr/bin/env zsh
print -rn -- again
exit 10
ZSH
chmod +x "$stop_always"
SF_TEST_RUNTIME=$(jq -c --arg hook "$stop_always" \
  '.harness.stop=[$hook] | .harness.max_requests_per_turn=1' \
  <<<"$SF_TEST_RUNTIME")
typeset limit_session="$tmp/stop-limit.jsonl"
sf_test_session "$limit_session"
stream=$(sf_test_turn bounded "$limit_session")
print -r -- "$stream" | jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "context")) | length) == 1 and
  $events[-2].role == "assistant" and $events[-2].stop == "end" and
  $events[-1].message == "provider request limit reached: 1"
' >/dev/null
jq -L "$ROOT/lib" -e -s '
  include "runtime/schema";
  (.[1:] | canonical_session_records) and .[-1].stop == "end"
' "$limit_session" >/dev/null

# Cancellation after feedback commit stops the retry without rolling back the
# completed assistant or stop context.
typeset cancel_pipe="$tmp/cancel.pipe"
mkfifo "$cancel_pipe"
typeset cancel_backend="$tmp/cancel-backend"
cat >"$cancel_backend" <<ZSH
#!/usr/bin/env zsh
request=\$(cat)
if jq -e '.messages[-1].role == "user" and
    (.messages[-1].content[0].text | contains("<stop hook=\\"stop-once\\">"))' \
    <<<"\$request" >/dev/null; then
  print -r -- ready >"$cancel_pipe"
  sleep 10
else
  print -r -- '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"original\\n"}]}'
fi
ZSH
chmod +x "$cancel_backend"

SF_TEST_RUNTIME=$(jq -c --arg hook "$stop_once" --arg backend "$cancel_backend" '
  .harness.stop=[$hook] | .harness.max_requests_per_turn=8 | .backend.command=$backend
' <<<"$SF_TEST_RUNTIME")
typeset cancel_session="$tmp/stop-cancel.jsonl"
typeset cancel_stream="$tmp/stop-cancel.stream"
sf_test_session "$cancel_session"
"$ROOT/bin/shellfish" exec --jsonl --session "$cancel_session" \
  < <(print -r -- '{"type":"message","role":"user","content":[{"type":"text","text":"wait for retry"}]}') \
  >"$cancel_stream" &
integer cancel_pid=$! cancel_status=0
typeset cancel_sync
read -r cancel_sync <"$cancel_pipe"
kill -TERM "$cancel_pid"
wait "$cancel_pid" || cancel_status=$?
(( cancel_status == 143 ))
jq -eRn '
  [inputs | fromjson] as $events |
  ($events | map(select(.type == "context" and .tag == "stop")) | length) == 1 and
  $events[-1].role == "assistant" and $events[-1].stop == "end"
' <"$cancel_stream" >/dev/null
jq -L "$ROOT/lib" -e -s '
  include "runtime/schema";
  (.[1:] | canonical_session_records) and
  ([.[] | select(.type == "context" and .tag == "stop")] | length) == 1
' "$cancel_session" >/dev/null
