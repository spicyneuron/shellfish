#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh \
  libexec/tui/render/messages.zsh libexec/tui/render/hooks.zsh \
  libexec/tui/render/tools.zsh \
  libexec/tui/render/terminal.zsh libexec/tui/render/view.zsh \
  libexec/tui/transport.zsh libexec/tui/editor.zsh libexec/tui/controller.zsh
sf_test_tmp controller
typeset SF_ENTRY="$ROOT/bin/shellfish"

# Keep unit tests PTY-free; the real worker lifecycle is covered by tests/pty.
sf_tui_heartbeat_arm() { return 0; }

# Turn events are only legal once a session exists.
SF_PRESENT_SESSION="$tmp/session.jsonl"
SF_PRESENT_STATE=working
sf_tui_decoded assistant_start
sf_tui_decoded assistant_message_delta 0 'part '
sf_tui_decoded assistant_reasoning_delta 1 thought
sf_tui_decoded assistant_message_delta 2 done
sf_tui_decoded turn_usage '14 ↑ 2 ↓' 1
assert_equal "${SF_PRESENT_IDENTITY} · 14 ↑ 2 ↓" "$SF_PRESENT_FOOTER"

sf_tui_decoded permission_request permission_1 shell pwd 'host access' sh
assert_equal permission "$SF_PRESENT_STATE"
assert_equal permission_1 "$SF_PRESENT_PERMISSION_ID"
assert_equal shell "$SF_PRESENT_PERMISSION_TOOL"
assert_equal $'pwd\n\nReason: host access' "$SF_PRESENT_PERMISSION_TEXT"
assert_equal sh "$SF_PRESENT_PERMISSION_LANGUAGE"
assert_equal 3 "$SF_PRESENT_PERMISSION_PREVIEW_LENGTH"

SF_PRESENT_STATE=working
SF_PRESENT_PERMISSION_ID=''
sf_tui_decoded handoff '["/tmp/custom command","","arg"]'
assert_equal '/tmp/custom command,,arg' "${(j:,:)SF_PRESENT_HANDOFF}"

typeset updated_runtime
updated_runtime=$(jq -c '
  del(.type,.format_version,.cwd,.created) |
  .backend.name = "updated" | .profile.request.model = "new-model" |
  .profile.context_window = null
' "$ROOT/tests/fixtures/session/header-only.jsonl")
sf_tui_decoded session_update "$updated_runtime"
assert_equal "$updated_runtime" "$SF_PRESENT_RUNTIME"
assert_equal updated/new-model "$SF_PRESENT_IDENTITY"
assert_equal updated/new-model "$SF_PRESENT_FOOTER"

# State passes through the live transport without stopping the chat.
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=( '{"type":"state","name":"live/status","value":"ready"}' )
sf_tui_pending_next || fail 'a live state record was rejected'
assert_equal working "$SF_PRESENT_STATE"

if sf_tui_decoded not-supported; then
  fail 'unsupported exec output was accepted'
fi

# Cancellation keeps the transport open so exec can emit durable recovery before EOF.
typeset -gi cancel_signals=0 cancel_stops=0 cancel_reloads=0
functions[sf_tui_transport_signal_saved]=$functions[sf_tui_transport_signal]
functions[sf_tui_transport_stop_saved]=$functions[sf_tui_transport_stop]
functions[sf_tui_recover_saved]=$functions[sf_tui_recover]
sf_tui_transport_signal() {
  assert_equal USR1 "$1"
  (( ++cancel_signals ))
}
sf_tui_transport_stop() { (( ++cancel_stops )); }
sf_tui_recover() { (( ++cancel_reloads )); }
SF_PRESENT_STATE=working
SF_PRESENT_QUEUE=( queued )
sf_tui_cancel
assert_equal cancelling "$SF_PRESENT_STATE"
assert_equal 1 "$cancel_signals"
assert_equal 0 "$cancel_stops"
assert_equal 0 "$cancel_reloads"
assert_equal queued "${(j:,:)SF_PRESENT_QUEUE}"
functions[sf_tui_transport_signal]=$functions[sf_tui_transport_signal_saved]
functions[sf_tui_transport_stop]=$functions[sf_tui_transport_stop_saved]
functions[sf_tui_recover]=$functions[sf_tui_recover_saved]
unfunction sf_tui_transport_signal_saved sf_tui_transport_stop_saved sf_tui_recover_saved

# Malformed exec output stops the chat. The live transcript cannot be trusted
# past it, and only the durable session can replace it.
cp "$SF_TEST_SESSIONS/complete.jsonl" "$tmp/recover.jsonl"
sf_tui_reload "$tmp/recover.jsonl" || fail "$SF_PRESENT_ERROR"
sf_tui_terminal_reset
sf_tui_event assistant_message_delta 0 speculative
SF_PRESENT_SESSION=$tmp/recover.jsonl
SF_PRESENT_STATE=working
sf_tui_transport_reset
SF_PRESENT_QUEUE=( queued )
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY='' ZLE_CALLS=''
zle() {
  ZLE_CALLS+="${ZLE_CALLS:+,}$*"
}
exec {SF_TUI_TRANSPORT_OUTPUT_FD}< <(print -r -- broken)
sf_tui_exec_ready "$SF_TUI_TRANSPORT_OUTPUT_FD"
assert_equal working "$SF_PRESENT_STATE"
sf_tui_heartbeat_tick
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal 'exec sent invalid JSONL' "$SF_PRESENT_ERROR"
assert_equal 0 "${#SF_PRESENT_QUEUE}"
[[ $PREDISPLAY == *'Shellfish stopped: exec sent invalid JSONL'* ]] ||
  fail 'the stopped view did not report the failure'
[[ $PREDISPLAY == *'/refresh'* && $PREDISPLAY == *'/quit'* ]] ||
  fail 'the stopped view did not say which prompts it accepts'
# Draining what the child already sent cannot return to the failed renderer.
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
sf_tui_heartbeat_tick
assert_equal stopped "$SF_PRESENT_STATE"
# A stopped chat runs no prompt, but still answers the two client commands.
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

# Buffered transport records are applied as one semantic batch, leaving nothing
# pending and never taking the line away from the active editor.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_STATE=working
SF_PRESENT_ACTION=''
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=(
  '{"type":"_assistant_message_delta","index":0,"text":"one two three "}'
  '{"type":"_assistant_message_delta","index":0,"text":"four five six "}'
  '{"type":"_assistant_message_delta","index":0,"text":"seven eight"}'
  '{"type":"_assistant_end","stop":"end"}'
  '{"type":"assistant","stop":"end","content":[{"type":"text","text":"one two three four five six seven eight"}]}'
  '{"type":"hook_result","hook":"project","script":"test","model_context":"later"}'
)
BUFFER=''
CURSOR=0
COLUMNS=12
LINES=10
ZLE_CALLS=''

sf_tui_heartbeat_tick
if sf_tui_transport_has_pending; then
  fail 'transport events remained after the heartbeat batch'
fi
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal 0 "$SF_PRESENT_PENDING_ROWS"
[[ $ZLE_CALLS != *accept-line* ]] ||
  fail 'transport batch left the active editor'

# Every frame shape drains completely in one heartbeat: a live tool-call delta
# after streamed text, the durable call that confirms it, and a tool-only
# response carrying no assistant content. Presentation order is the renderer's
# contract and is covered by tests/pty.
typeset -a frames=(
  '{"type":"_assistant_message_delta","index":0,"text":"before tool"}
{"type":"_assistant_tool_call_delta","index":1,"id":"call_1"}'
  '{"type":"_assistant_message_delta","index":0,"text":"before tool"}
{"type":"_assistant_tool_call_delta","index":1,"id":"call_1"}
{"type":"_assistant_end","stop":"tool_calls"}
{"type":"assistant","stop":"tool_calls","content":[{"type":"text","text":"before tool"}]}
{"type":"tool_call","id":"call_1","name":"shell","input":{"command":"true"}}'
  '{"type":"_assistant_start"}
{"type":"_assistant_end","stop":"tool_calls"}
{"type":"assistant","stop":"tool_calls","content":[]}
{"type":"tool_call","id":"call_2","name":"shell","input":{"command":"true"}}'
)
for frame in "${frames[@]}"; do
  sf_tui_reset
  sf_tui_terminal_reset
  SF_PRESENT_STATE=working
  sf_tui_transport_reset
  SF_TUI_TRANSPORT_LINES=( "${(@f)frame}" )
  sf_tui_heartbeat_tick
  if sf_tui_transport_has_pending; then
    fail "a heartbeat left part of a frame pending: $frame"
  fi
  [[ $SF_PRESENT_STATE != stopped ]] || fail "a heartbeat rejected its frame: $frame"
done

# Successful completion stages the FIFO head as the next ordinary user turn.
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

# A completed turn wins a cancellation race, while queued prompts are still discarded.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event activity_start
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=cancelling
SF_PRESENT_QUEUE=( speculative )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
SF_TUI_TRANSPORT_EXIT_DETAIL=''
sf_tui_exec_finish
assert_equal idle "$SF_PRESENT_STATE"
assert_equal 0 "${#SF_PRESENT_QUEUE}"
assert_equal error "$SF_PRESENT_KIND[-1]"

# Successful cancellation without a queued-prompt diagnostic still clears
# standalone activity at process completion.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event activity_start
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=cancelling
SF_PRESENT_QUEUE=()
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
SF_TUI_TRANSPORT_EXIT_DETAIL=''
sf_tui_exec_finish
assert_equal idle "$SF_PRESENT_STATE"
assert_equal 0 "${#SF_PRESENT_KIND}"

# An uncertain exec boundary discards follow-up prompts before recovery.
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

# A persisted turn error is the whole outcome, so completion adds no second
# report and chat stays usable.
sf_tui_reset
sf_tui_terminal_reset
cp "$SF_TEST_SESSIONS/interrupted.jsonl" "$tmp/failed.jsonl"
print -r -- '{"type":"turn_error","message":"test backend failure"}' >>"$tmp/failed.jsonl"
SF_PRESENT_SESSION="$tmp/failed.jsonl"
SF_PRESENT_STATE=working
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=( '{"type":"turn_error","message":"test backend failure"}' )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
SF_TUI_TRANSPORT_EXIT_DETAIL='test backend failure'
sf_tui_heartbeat_tick
assert_equal idle "$SF_PRESENT_STATE"

# A persisted cancellation is the complete user-facing outcome, so the
# cancelling state adds nothing to it.
sf_tui_reset
sf_tui_terminal_reset
cp "$SF_TEST_SESSIONS/interrupted.jsonl" "$tmp/cancelled.jsonl"
print -r -- '{"type":"turn_error","message":"Cancelled."}' >>"$tmp/cancelled.jsonl"
SF_PRESENT_SESSION="$tmp/cancelled.jsonl"
SF_PRESENT_STATE=cancelling
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=(
  '{"type":"turn_error","message":"Cancelled."}'
)
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=130
sf_tui_heartbeat_tick
assert_equal idle "$SF_PRESENT_STATE"

# A terminated exec ends the turn as an ordinary failure, and chat stays usable.
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

# A permission prompt cannot be answered once the child is gone. The chat stops
# rather than guessing what the undecided turn did.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=permission
SF_PRESENT_PERMISSION_ID=permission_1
functions[sf_tui_transport_reply_saved]=$functions[sf_tui_transport_reply]
sf_tui_transport_reply() { return 1; }
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

SF_PRESENT_QUEUE=( one two )
sf_tui_discard_queue
assert_equal 'Discarded 2 queued prompts. Use ↑↓ keys to recover.' "$REPLY"
assert_equal 0 "${#SF_PRESENT_QUEUE}"

# A queued client command is answered by the client, never sent as a prompt.
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

# Creation queues prompts and rejects turn events until it announces a session.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION=''
SF_PRESENT_STATE=working
sf_tui_submit early
assert_equal repaint "$REPLY"
assert_equal early "${(j:,:)SF_PRESENT_QUEUE}"
if sf_tui_decoded assistant_start; then
  fail 'creation accepted a turn event'
fi
sf_tui_decoded session_created "$tmp/new.jsonl"
assert_equal "$tmp/new.jsonl" "$SF_PRESENT_SESSION"
assert_equal "$SF_ENTRY run --jsonl --session $tmp/new.jsonl" "${(j: :)SF_TUI_TRANSPORT_COMMAND}"
if sf_tui_decoded session_created "$tmp/second.jsonl"; then
  fail 'creation announced a second session'
fi
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
sf_tui_exec_finish
assert_equal queued "$SF_PRESENT_STATE"
assert_equal early "$SF_PRESENT_SUBMITTED"

# Creation that announced nothing leaves no session to rebuild from, so the
# chat stops with the failure and offers only to quit.
for code in 0 9; do
  sf_tui_reset
  sf_tui_terminal_reset
  SF_PRESENT_SESSION=''
  SF_PRESENT_STATE=working
  SF_PRESENT_QUEUE=()
  sf_tui_event hook_activity session_start hook working
  SF_TUI_TRANSPORT_EOF=1
  SF_TUI_TRANSPORT_EXIT_STATUS=$code
  SF_TUI_TRANSPORT_EXIT_DETAIL='startup failure'
  sf_tui_exec_finish
  assert_equal stopped "$SF_PRESENT_STATE"
  [[ $SF_PRESENT_ERROR == 'Session creation failed.'* ]] ||
    fail "creation failure reported $SF_PRESENT_ERROR"
  [[ $POSTDISPLAY != *'[r]'* ]] || fail 'refresh was offered without a session'
done
