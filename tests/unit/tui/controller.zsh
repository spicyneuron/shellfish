#!/usr/bin/env zsh

# Turn workflow: draining core output, permissions, queues, and recovery.

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh libexec/tui/project.zsh \
  libexec/tui/transport.zsh libexec/tui/editor.zsh libexec/tui/controller.zsh
sf_test_tmp controller
typeset SF_ENTRY="$ROOT/bin/shellfish"
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY='' ZLE_CALLS=''
typeset -gi COLUMNS=80 LINES=20
zle() { ZLE_CALLS+="${ZLE_CALLS:+,}$*" }

# Avoid the PTY worker.
sf_tui_heartbeat_arm() { return 0; }

pump() {
  SF_TUI_TRANSPORT_LINES=( "$@" )
  sf_tui_pending_next || fail 'draining core output failed'
}

# Replay complete session lines directly and reject invalid physical input.
typeset replay="$tmp/replay.jsonl" malformed="$tmp/malformed.jsonl" torn="$tmp/torn.jsonl"
cp "$SF_TEST_SESSIONS/complete.jsonl" "$replay"
SF_PRESENT_SESSION=$replay
SF_PRESENT_STATE=idle
sf_tui_load "$replay" || fail 'direct session replay failed'
assert_equal test/fake-model "$SF_PRESENT_IDENTITY"
print -r -- 'not json' >"$malformed"
sf_tui_load "$malformed" && fail 'malformed session replay succeeded'
assert_equal "cannot present session: $malformed" "$SF_PRESENT_ERROR"
print -n -r -- '{"type":"user"' >"$torn"
sf_tui_load "$torn" && fail 'incomplete session replay succeeded'
assert_equal "cannot read incomplete session: $torn" "$SF_PRESENT_ERROR"

# A cleared hook draft retracts its transient activity.
SF_PRESENT_SESSION="$tmp/session.jsonl"
SF_PRESENT_STATE=working
sf_tui_reset
pump '{"type":"_hook_draft","lifecycle":"session_start","id":"1","user_text":"git_environment · Loading git environment…"}'
sf_tui_transcript 79 20
[[ $SF_PRESENT_VIEWPORT_TEXT == *'Loading git environment'* ]] ||
  fail 'hook activity did not reach the viewport'
pump '{"type":"_hook_draft","lifecycle":"session_start","id":"1","user_text":""}'
sf_tui_transcript 79 20
[[ $SF_PRESENT_VIEWPORT_TEXT != *'Loading git environment'* ]] ||
  fail 'silent hook activity did not leave the viewport'

# Model context settles under its lifecycle without exposing model text.
sf_tui_reset
pump '{"type":"_hook_draft","lifecycle":"session_start","id":"2","user_text":"git_environment · Loading git environment…"}'
pump '{"type":"hook_result","lifecycle":"session_start","id":"2","model_text":"Git branch: secret"}'
sf_tui_transcript 79 20
[[ $SF_PRESENT_VIEWPORT_TEXT == *'↪ session_start'* &&
    $SF_PRESENT_VIEWPORT_TEXT != *'Loading git environment'* &&
    $SF_PRESENT_VIEWPORT_TEXT != *'Git branch: secret'* ]] ||
  fail 'model-only hook result did not settle as private context'

# Present one turn.
SF_PRESENT_SESSION="$tmp/session.jsonl"
SF_PRESENT_STATE=working
sf_tui_reset
sf_tui_terminal_reset
pump '{"type":"_assistant_start"}' \
  '{"type":"_assistant_message_delta","index":0,"text":"part "}' \
  '{"type":"_assistant_reasoning_delta","index":1,"text":"thought"}' \
  '{"type":"_assistant_end","stop":"end"}' \
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"part "},{"type":"reasoning","text":"thought"}],"usage":{"input_tokens":14,"output_tokens":2}}'
assert_equal "${SF_PRESENT_IDENTITY} · 14 ↑ 2 ↓" "$SF_PRESENT_FOOTER"
sf_tui_transcript 79 20
[[ $SF_PRESENT_VIEWPORT_TEXT == *part* ]] || fail 'the turn did not reach the viewport'
[[ ${SF_PRESENT_VIEWPORT_TEXT//part } != *part* ]] ||
  fail 'the durable record repeated the streamed text'

# Hold the turn for a permission decision.
pump '{"type":"_tool_permission_request","id":"permission_1","tool":{"name":"shell","input":{"command":"pwd"}},"reason":"host access","preview":"pwd"}'
assert_equal permission "$SF_PRESENT_STATE"
assert_equal permission_1 "$SF_PRESENT_PERMISSION_ID"
assert_equal shell "$SF_PRESENT_PERMISSION_TOOL"
assert_equal $'pwd\n\nReason: host access' "$SF_PRESENT_PERMISSION_TEXT"

# Capture a handoff request.
SF_PRESENT_STATE=working
SF_PRESENT_PERMISSION_ID=''
pump '{"type":"_handoff","argv":["/tmp/custom command","","arg"]}'
assert_equal '/tmp/custom command,,arg' "${(j:,:)SF_PRESENT_HANDOFF}"

# Apply runtime updates.
typeset updated_runtime
updated_runtime=$(jq -c '
  del(.type,.format_version,.cwd,.created) |
  .backend.command = "/updated/run" | .request.model = "new-model" |
  .context_window = null
' "$SF_TEST_SESSIONS/header-only.jsonl")
pump "$(jq -cn --argjson runtime "$updated_runtime" \
  '{type:"_session_update",runtime:$runtime}')"
assert_equal updated/new-model "$SF_PRESENT_IDENTITY"
assert_equal updated/new-model "$SF_PRESENT_FOOTER"

# Ignore live state records without disturbing the turn.
SF_PRESENT_STATE=working
pump '{"type":"state","name":"live/status","value":"ready"}'
assert_equal working "$SF_PRESENT_STATE"

# Cancel active turns.
typeset -gi cancel_signals=0 cancel_stops=0
functions[sf_tui_transport_signal_saved]=$functions[sf_tui_transport_signal]
functions[sf_tui_transport_stop_saved]=$functions[sf_tui_transport_stop]
sf_tui_transport_signal() {
  assert_equal USR1 "$1"
  (( ++cancel_signals ))
}
sf_tui_transport_stop() { (( ++cancel_stops )) }
SF_PRESENT_STATE=working
SF_PRESENT_QUEUE=( queued )
sf_tui_cancel
assert_equal cancelling "$SF_PRESENT_STATE"
assert_equal 1 "$cancel_signals"
assert_equal 0 "$cancel_stops"
assert_equal queued "${(j:,:)SF_PRESENT_QUEUE}"
functions[sf_tui_transport_signal]=$functions[sf_tui_transport_signal_saved]
functions[sf_tui_transport_stop]=$functions[sf_tui_transport_stop_saved]
unfunction sf_tui_transport_signal_saved sf_tui_transport_stop_saved

# Invalid core output stops the client without retracting scrollback.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=working
sf_tui_action message_start agent
sf_tui_action message_delta 0 text $'committed\nnext\n' ''
sf_tui_transcript 20 20
sf_tui_terminal_stage
sf_tui_terminal_finish
typeset committed=$PREDISPLAY
sf_tui_terminal_restore
SF_PRESENT_QUEUE=( queued )
sf_tui_transport_reset
exec {SF_TUI_TRANSPORT_OUTPUT_FD}< <(print -r -- broken)
sf_tui_exec_ready "$SF_TUI_TRANSPORT_OUTPUT_FD"
assert_equal working "$SF_PRESENT_STATE"
sf_tui_heartbeat_tick
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal 'exec sent invalid JSONL' "$SF_PRESENT_ERROR"
assert_equal 0 "${#SF_PRESENT_QUEUE}"
[[ $committed == *committed* ]] || fail 'committed rows were never written'
[[ $PREDISPLAY == *'Shellfish stopped: exec sent invalid JSONL'* ]] ||
  fail 'the stopped view did not report the failure'
[[ $PREDISPLAY == *'/refresh'* && $PREDISPLAY == *'/quit'* ]] ||
  fail 'the stopped view did not say which prompts it accepts'

# Preserve stopped state at EOF.
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
sf_tui_heartbeat_tick
assert_equal stopped "$SF_PRESENT_STATE"

# Restrict stopped prompts.
sf_tui_submit 'what happened?'
assert_equal ignore "$REPLY"
assert_equal '' "$SF_PRESENT_ACTION"
sf_tui_submit /refresh
assert_equal quit "$REPLY"
assert_equal handoff "$SF_PRESENT_ACTION"
assert_equal "$SF_ENTRY --clear --session $tmp/recover.jsonl" \
  "${(j: :)SF_PRESENT_HANDOFF}"
SF_PRESENT_ACTION=''
SF_PRESENT_HANDOFF=()
sf_tui_submit /q
assert_equal quit "$SF_PRESENT_ACTION"
SF_PRESENT_ACTION=''
SF_PRESENT_STATE=idle
SF_PRESENT_ERROR=''

# Start the next queued turn.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_STATE=working
SF_PRESENT_QUEUE=( first second )
SF_PRESENT_HANDOFF=()
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
sf_tui_exec_finish
assert_equal queued "$SF_PRESENT_STATE"
assert_equal first "$SF_PRESENT_SUBMITTED"
assert_equal second "$SF_PRESENT_QUEUE[1]"

# Resolve cancellation races.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_activity_start
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=cancelling
SF_PRESENT_QUEUE=( speculative )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
SF_TUI_TRANSPORT_EXIT_DETAIL=''
sf_tui_exec_finish
assert_equal idle "$SF_PRESENT_STATE"
assert_equal 0 "${#SF_PRESENT_QUEUE}"
# The core records its own cancellation, so the client reports only what it
# dropped on the way out.
sf_tui_transcript 79 20
[[ $SF_PRESENT_VIEWPORT_TEXT == *'✕ Discarded 1 queued prompt'* ]] ||
  fail "discarded queue was not reported: $SF_PRESENT_VIEWPORT_TEXT"

# Discard queues after uncertain exits.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=working
SF_PRESENT_QUEUE=( speculative )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
SF_TUI_TRANSPORT_EXIT_DETAIL='backend failed'
sf_tui_exec_finish
assert_equal 0 "${#SF_PRESENT_QUEUE}"
assert_equal idle "$SF_PRESENT_STATE"

# A durable failure is reported by the core, so the client adds no heading of
# its own. Rows committed during the tick have already left the queue.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=working
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=( '{"type":"error","user_text":"test backend failure"}' )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
SF_TUI_TRANSPORT_EXIT_DETAIL='test backend failure'
sf_tui_heartbeat_tick
assert_equal idle "$SF_PRESENT_STATE"
sf_tui_transcript 79 20
[[ $SF_PRESENT_VIEWPORT_TEXT != *'Exec process failed'* ]] ||
  fail "a settled error was reported twice: $SF_PRESENT_VIEWPORT_TEXT"

# Recover from terminated execs.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=working
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=143
SF_TUI_TRANSPORT_EXIT_DETAIL=''
sf_tui_exec_finish
assert_equal idle "$SF_PRESENT_STATE"
sf_tui_submit next
assert_equal submit "$REPLY"
assert_equal next "$SF_PRESENT_SUBMITTED"

# Stop on failed permission replies.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=permission
SF_PRESENT_PERMISSION_ID=permission_1
functions[sf_tui_transport_reply_saved]=$functions[sf_tui_transport_reply]
sf_tui_transport_reply() { return 1 }
if sf_tui_answer_permission approve; then
  fail 'an undeliverable decision was accepted'
fi
functions[sf_tui_transport_reply]=$functions[sf_tui_transport_reply_saved]
unfunction sf_tui_transport_reply_saved
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal 'cannot answer permission' "$SF_PRESENT_ERROR"
assert_equal '' "$SF_PRESENT_PERMISSION_ID"
SF_PRESENT_STATE=idle
SF_PRESENT_ERROR=''

# Run queued client commands.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=working
SF_PRESENT_ACTION=''
SF_PRESENT_HANDOFF=()
SF_PRESENT_QUEUE=( /refresh )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
sf_tui_exec_finish
assert_equal handoff "$SF_PRESENT_ACTION"
assert_equal "$SF_ENTRY --clear --session $tmp/recover.jsonl" \
  "${(j: :)SF_PRESENT_HANDOFF}"
SF_PRESENT_ACTION=''
SF_PRESENT_HANDOFF=()

# Creation names the session and renders its system context before live hooks.
sf_tui_reset
sf_tui_terminal_reset
SF_TUI_PROJECT_MODE=live
SF_PRESENT_SESSION=''
SF_PRESENT_STATE=working
SF_PRESENT_QUEUE=()
sf_tui_submit early
assert_equal repaint "$REPLY"
assert_equal early "${(j:,:)SF_PRESENT_QUEUE}"
pump "$(jq -cn --arg path "$tmp/new.jsonl" '{type:"_session_load",path:$path}')" \
  '{"type":"session","backend":{"command":"/test/run"},"request":{"model":"model"}}' \
  '{"type":"system","content":"instructions"}' \
  '{"type":"_hook_draft","lifecycle":"session_start","id":"1","user_text":"setup · working"}'
assert_equal working "$SF_PRESENT_STATE"
assert_equal "$tmp/new.jsonl" "$SF_PRESENT_SESSION"
assert_equal "$SF_ENTRY run --jsonl --session $tmp/new.jsonl" \
  "${(j: :)SF_TUI_TRANSPORT_COMMAND}"
sf_tui_transcript 79 20
[[ $SF_PRESENT_VIEWPORT_TEXT == *instructions*'setup · working'* ]] ||
  fail 'startup did not render system context before live hook activity'
pump '{"type":"hook_result","lifecycle":"session_start","id":"1","user_text":"setup · ready"}'
sf_tui_transcript 79 20
[[ $SF_PRESENT_VIEWPORT_TEXT == *instructions*'setup · ready'* &&
    $SF_PRESENT_VIEWPORT_TEXT != *'setup · working'* ]] ||
  fail 'startup hook activity did not settle in place'
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
sf_tui_exec_finish
assert_equal queued "$SF_PRESENT_STATE"
assert_equal early "$SF_PRESENT_SUBMITTED"

# Stop failed session creation.
typeset code
for code in 0 9; do
  sf_tui_reset
  sf_tui_terminal_reset
  SF_PRESENT_SESSION=''
  (( ! code )) || SF_PRESENT_SESSION="$tmp/failed.jsonl"
  SF_PRESENT_CREATING=1
  SF_PRESENT_STATE=working
  SF_PRESENT_QUEUE=()
  SF_TUI_TRANSPORT_EOF=1
  SF_TUI_TRANSPORT_EXIT_STATUS=$code
  SF_TUI_TRANSPORT_EXIT_DETAIL='startup failure'
  sf_tui_exec_finish
  assert_equal stopped "$SF_PRESENT_STATE"
  [[ $SF_PRESENT_ERROR == 'Session creation failed.'* ]] ||
    fail "creation failure reported $SF_PRESENT_ERROR"
  assert_equal '' "$SF_PRESENT_SESSION"
  [[ $POSTDISPLAY != *'[r]'* ]] || fail 'refresh was offered without a session'
done

print -r -- ok
