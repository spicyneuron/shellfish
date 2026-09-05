#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/nodes.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/rows.zsh libexec/tui/render/viewport.zsh \
  libexec/tui/render/terminal.zsh libexec/tui/render/view.zsh \
  libexec/tui/transport.zsh libexec/tui/editor.zsh libexec/tui/controller.zsh
sf_test_tmp controller

# Keep unit tests PTY-free; the real worker lifecycle is covered by tests/pty.
sf_tui_heartbeat_arm() { return 0; }

SF_PRESENT_STATE=working
sf_tui_add activity '' '' '' open
sf_tui_decoded backend_request_start
assert_equal 'section,activity' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal agent "$SF_PRESENT_NODE_ROLE[-1]"
sf_tui_decoded assistant_delta 'part '
sf_tui_decoded assistant_reasoning_delta thought
sf_tui_decoded assistant_delta done
sf_tui_decoded turn_usage '14 ↑ 2 ↓' 1
assert_equal 'section,message,reasoning,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal "${SF_PRESENT_IDENTITY} · 14 ↑ 2 ↓" "$SF_PRESENT_FOOTER"
assert_equal 1 "$SF_PRESENT_REASONING_TOKENS"
assert_equal '' "$SF_PRESENT_NODE_META[3]"

sf_tui_reset
sf_tui_decoded assistant_reasoning_delta current
sf_tui_decoded turn_usage '20 ↑ 4 ↓' 3
assert_equal 3 "$SF_PRESENT_NODE_META[-1]"

sf_tui_reset
sf_tui_decoded turn_usage '20 ↑ 4 ↓' 5
sf_tui_decoded assistant_reasoning_delta current
sf_tui_decoded assistant_commit
assert_equal 5 "$SF_PRESENT_NODE_META[-1]"

sf_tui_decoded permission_request permission_1 shell pwd 'host access' sh
assert_equal permission "$SF_PRESENT_STATE"
assert_equal permission_1 "$SF_PRESENT_PERMISSION_ID"
assert_equal shell "$SF_PRESENT_PERMISSION_TOOL"
assert_equal $'pwd\n\nReason: host access' "$SF_PRESENT_PERMISSION_TEXT"
assert_equal sh "$SF_PRESENT_PERMISSION_LANGUAGE"
assert_equal 3 "$SF_PRESENT_PERMISSION_PREVIEW_LENGTH"
assert_equal notice "$SF_PRESENT_NODE_TYPE[-1]"
assert_equal 'Permission: shell' "$SF_PRESENT_NODE_HEADING[-1]"

SF_PRESENT_STATE=working
SF_PRESENT_PERMISSION_ID=''
sf_tui_decoded handoff '["/tmp/custom command","","arg"]'
assert_equal '/tmp/custom command,,arg' "${(j:,:)SF_PRESENT_HANDOFF}"

typeset node_types="${(j:,:)SF_PRESENT_NODE_TYPE}"
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
assert_equal "$node_types" "${(j:,:)SF_PRESENT_NODE_TYPE}"

if sf_tui_decoded not-supported; then
  fail 'unsupported exec output was accepted'
fi

# Cancellation keeps the transport open so exec can emit durable recovery before EOF.
typeset -gi cancel_signals=0 cancel_stops=0 cancel_reloads=0
functions[sf_tui_transport_signal_saved]=$functions[sf_tui_transport_signal]
functions[sf_tui_transport_stop_saved]=$functions[sf_tui_transport_stop]
functions[sf_tui_recover_saved]=$functions[sf_tui_recover]
sf_tui_transport_signal() { (( ++cancel_signals )); }
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

# A notice is role-agnostic. It closes a live tail without creating a system
# section or changing which message role owns the surrounding section.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_add activity '' '' '' open
sf_tui_notice warning 'Before response'
assert_equal notice "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal '' "$SF_PRESENT_LAST_ROLE"

sf_tui_reset
sf_tui_event assistant_delta before
sf_tui_notice warning 'Heads up' detail
sf_tui_event assistant_delta after
assert_equal 'section,message,notice,message' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal agent "$SF_PRESENT_LAST_ROLE"
assert_equal closed "$SF_PRESENT_NODE_STATE[2]"
BUFFER=''
CURSOR=0
sf_tui_viewport 80 20 "$SF_PRESENT_CURSOR"
sf_tui_terminal_stage
sf_tui_terminal_finish
[[ $PREDISPLAY == *$'ℹ Heads up\n  detail'* ]] || fail 'Notice did not survive flushing'
sf_tui_reload "$SF_TEST_SESSIONS/complete.jsonl" || fail "$SF_PRESENT_ERROR"
assert_equal 0 "${#${(M)SF_PRESENT_NODE_TYPE:#notice}}"
assert_equal "${SF_PRESENT_IDENTITY} · 1 ↑ 1 ↓" "$SF_PRESENT_FOOTER"

# Hook displays split a live tool into contiguous presentation segments. The
# result still completes the resumed segment.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event tool_call call_1 shell '{"command":"true"}'
sf_tui_decoded hook_display pre_tool_use /tmp/progress working true
assert_equal 'section,tool_call,tool_result,notice,tool_result' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal progress "$SF_PRESENT_NODE_HEADING[4]"
assert_equal pre_tool_use "$SF_PRESENT_NODE_META[4]"
assert_equal '' "$SF_PRESENT_NODE_STATUS[3]"
assert_equal closed "$SF_PRESENT_NODE_STATE[3]"
assert_equal open "$SF_PRESENT_NODE_STATE[5]"
sf_tui_event tool_result call_1 0 done
assert_equal done "$SF_PRESENT_NODE_BODY[5]"
assert_equal closed "$SF_PRESENT_NODE_STATE[5]"

# A detected sandbox denial rides its own result rather than interrupting the tool.
sf_tui_reset
sf_tui_event tool_call call_1 shell '{"command":"true"}'
sf_tui_decoded tool_result call_1 1 denied '' '' sandbox_denial
assert_equal 'section,tool_call,tool_result' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal sandbox_denial "$SF_PRESENT_NODE_SANDBOX_DENIAL[3]"
assert_equal denied "$SF_PRESENT_NODE_BODY[3]"

# An execution error abandons rather than resumes the live tool.
sf_tui_reset
sf_tui_event tool_call call_1 shell '{"command":"false"}'
sf_tui_decoded exec_error failed
assert_equal 'section,tool_call,tool_result,notice' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal '' "$SF_PRESENT_NODE_STATUS[3]"
assert_equal closed "$SF_PRESENT_NODE_STATE[3]"
assert_equal error "$SF_PRESENT_NODE_ROLE[4]"
assert_equal 0 "${#SF_PRESENT_TOOL_ORDER}"
assert_equal '' "$SF_PRESENT_TOOL_CURRENT"

# Sequential tool calls remain completable across pre- and post-hook script output.
sf_tui_reset
sf_tui_event tool_call call_1 shell one
sf_tui_event tool_call call_2 shell two
sf_tui_decoded hook_display pre_tool_use /tmp/pre first true
sf_tui_event tool_result call_1 0 first
sf_tui_decoded hook_display post_tool_use /tmp/post first-done true
sf_tui_decoded hook_display pre_tool_use /tmp/pre second true
sf_tui_event tool_result call_2 0 second
sf_tui_decoded hook_display post_tool_use /tmp/post second-done true
integer completed_tools=0 notices=0 node
for (( node = 1; node <= ${#SF_PRESENT_NODE_TYPE}; node++ )); do
  if [[ $SF_PRESENT_NODE_TYPE[node] == notice ]]; then
    (( ++notices ))
  elif [[ $SF_PRESENT_NODE_TYPE[node] == tool_result && $SF_PRESENT_NODE_STATUS[node] == 0 ]]; then
    (( ++completed_tools ))
  fi
done
assert_equal 4 "$notices"
assert_equal 2 "$completed_tools"
assert_equal 0 "${#SF_PRESENT_TOOL_ORDER}"
assert_equal '' "$SF_PRESENT_TOOL_CURRENT"

# A live hook display updates one notice and resumes the interrupted tool only
# after the hook invocation completes.
sf_tui_reset
sf_tui_event tool_call call_live shell run
sf_tui_decoded hook_display pre_tool_use /tmp/progress $'Checking\n' false
assert_equal 'section,tool_call,tool_result,notice' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal open "$SF_PRESENT_NODE_STATE[-1]"
sf_tui_decoded hook_display pre_tool_use /tmp/progress $'Checking policy\n' true
assert_equal 'section,tool_call,tool_result,notice,tool_result' "${(j:,:)SF_PRESENT_NODE_TYPE}"
assert_equal closed "$SF_PRESENT_NODE_STATE[4]"
assert_equal $'Checking policy\n' "$SF_PRESENT_NODE_BODY[4]"
assert_equal open "$SF_PRESENT_NODE_STATE[5]"
assert_equal pre_tool_use "$SF_PRESENT_NODE_META[4]"
sf_tui_event tool_result call_live 0 allowed

# Malformed bounded-exec output converges on authoritative reload rather than
# retaining the speculative live tail.
cp "$SF_TEST_SESSIONS/complete.jsonl" "$tmp/recover.jsonl"
sf_tui_reload "$tmp/recover.jsonl" || fail "$SF_PRESENT_ERROR"
sf_tui_terminal_reset
BUFFER=''
CURSOR=0
sf_tui_viewport 20 3 "$SF_PRESENT_CURSOR"
sf_tui_terminal_stage
sf_tui_terminal_finish
typeset flushed=$PREDISPLAY
[[ $flushed == *Hello* ]] || fail 'recovery setup did not flush its prefix'
sf_tui_event assistant_delta speculative
SF_PRESENT_SESSION=$tmp/recover.jsonl
SF_PRESENT_STATE=working
sf_tui_transport_reset
SF_PRESENT_PERMISSION_ID=stale
SF_PRESENT_PERMISSION_TOOL=stale
SF_PRESENT_PERMISSION_TEXT=stale
SF_PRESENT_PERMISSION_LANGUAGE=stale
SF_PRESENT_PERMISSION_PREVIEW_LENGTH=5
SF_PRESENT_PERMISSION_DRAFT=stale
SF_PRESENT_PERMISSION_CURSOR=5
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY='' ZLE_CALLS='' DRAWN=''
zle() {
  ZLE_CALLS+="${ZLE_CALLS:+,}$*"
  [[ $1 != -I ]] || DRAWN=$PREDISPLAY$BUFFER$POSTDISPLAY
}
exec {SF_TUI_TRANSPORT_OUTPUT_FD}< <(print -r -- broken)
sf_tui_exec_ready "$SF_TUI_TRANSPORT_OUTPUT_FD"
assert_equal working "$SF_PRESENT_STATE"
assert_equal 1 "${#SF_TUI_TRANSPORT_LINES}"
while [[ $SF_PRESENT_STATE == working ]] && sf_tui_transport_has_pending; do
  (( SF_PRESENT_PENDING_ROWS )) || sf_tui_heartbeat_tick
  if (( SF_PRESENT_PENDING_ROWS )); then
    sf_tui_line_finish
    sf_tui_line_init
  fi
done
assert_equal idle "$SF_PRESENT_STATE"
assert_equal '' "$SF_PRESENT_PERMISSION_ID"
assert_equal '' "$SF_PRESENT_PERMISSION_TOOL"
assert_equal '' "$SF_PRESENT_PERMISSION_TEXT"
assert_equal '' "$SF_PRESENT_PERMISSION_LANGUAGE"
assert_equal 0 "$SF_PRESENT_PERMISSION_PREVIEW_LENGTH"
assert_equal '' "$SF_PRESENT_PERMISSION_DRAFT"
assert_equal 0 "$SF_PRESENT_PERMISSION_CURSOR"
assert_equal notice "$SF_PRESENT_NODE_TYPE[-1]"
assert_equal 'Exec sent invalid JSONL.' "$SF_PRESENT_NODE_HEADING[-1]"
[[ ${(j:\n:)SF_PRESENT_NODE_BODY} != *speculative* ]] ||
  fail 'recovery retained speculative presentation text'
sf_tui_viewport 80 20 "$SF_PRESENT_CURSOR"
[[ $SF_PRESENT_VIEWPORT_TEXT != *Hello* ]] ||
  fail 'recovery repainted the flushed durable prefix'
[[ $ZLE_CALLS == *'-R'* ]] ||
  fail 'recovery did not repaint ZLE'

# An unmatched speculative prefix cannot survive authoritative recovery. Its
# saved cursor points past everything that remains and must be reset as well.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION=$tmp/recover.jsonl
SF_PRESENT_PREFIX_VISIBLE=1
sf_tui_add message agent '' 'streamed text that never reached the session' open
SF_PRESENT_CURSOR='1:30'
sf_tui_recover 'Cancelled.' || fail 'recovery rejected an unmatched open prefix'
assert_equal 1:0 "$SF_PRESENT_CURSOR"
sf_tui_viewport 80 20 "$SF_PRESENT_CURSOR" ||
  fail 'recovery left a cursor the viewport cannot render'

# Buffered transport records are applied as one semantic batch after older rows
# stop flushing. The bounded viewport still sends their display rows to
# scrollback in source order.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_STATE=working
SF_PRESENT_ACTION=''
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=(
  '{"type":"_assistant_delta","text":"one two three "}'
  '{"type":"_assistant_delta","text":"four five six "}'
  '{"type":"_assistant_delta","text":"seven eight"}'
  '{"type":"message","role":"assistant","stop":"end","content":[{"type":"text","text":"one two three four five six seven eight"}]}'
  '{"type":"context","hook":"project","script":"test","content":"later"}'
)
BUFFER=''
CURSOR=0
COLUMNS=12
LINES=10
ZLE_CALLS=''
typeset -a injections
typeset -gi assistant_highlight_calls=0
functions[sf_tui_markdown_saved]=$functions[sf_tui_markdown_highlight]
SF_PRESENT_HIGHLIGHT_ENABLED=1
sf_tui_markdown_highlight() {
  [[ $1 != 'one two three four five six seven eight' ]] ||
    (( ++assistant_highlight_calls ))
  sf_tui_markdown_saved "$@"
}

sf_tui_heartbeat_tick
assert_equal 1 "$assistant_highlight_calls"
if sf_tui_transport_has_pending; then
  fail 'transport events remained after the heartbeat batch'
fi
assert_equal closed "$SF_PRESENT_NODE_STATE[2]"
injections=( ${(M)SF_PRESENT_NODE_TYPE:#injection} )
assert_equal 1 "${#injections}"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal 0 "$SF_PRESENT_PENDING_ROWS"
[[ $ZLE_CALLS != *accept-line* ]] ||
  fail 'transport batch left the active editor'
integer context_node=${SF_PRESENT_NODE_TYPE[(i)injection]}
integer cursor_node=${SF_PRESENT_CURSOR%%:*}
(( cursor_node < context_node )) ||
  fail 'later context crossed the bounded assistant viewport'
functions[sf_tui_markdown_highlight]=$functions[sf_tui_markdown_saved]
unfunction sf_tui_markdown_saved
SF_PRESENT_HIGHLIGHT_ENABLED=0

# Completed assistant rows drain before the validated tool call is applied,
# including when the response is taller than one viewport.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_STATE=working
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=(
  '{"type":"_assistant_delta","text":"one\ntwo\nthree\nfour\nfive\nsix\nseven\nbefore tool"}'
  '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"text","text":"one\ntwo\nthree\nfour\nfive\nsix\nseven\nbefore tool"},{"type":"tool_call","id":"call_1","name":"shell","input":{"command":"true"}}]}'
)
BUFFER=''
CURSOR=0
COLUMNS=80
LINES=8
DRAWN=''
sf_tui_heartbeat_tick
(( ! ${#${(M)SF_PRESENT_NODE_TYPE:#tool_call}} )) ||
  fail 'tool call was applied in the assistant row frame'
assert_equal '' "$SF_PRESENT_TOOL_CURRENT"
sf_tui_transport_has_pending || fail 'tool call did not remain queued for the next frame'
typeset published
integer tool_ticks=0
while [[ -z $SF_PRESENT_TOOL_CURRENT ]] && (( ++tool_ticks < 10 )); do
  published=$DRAWN
  sf_tui_heartbeat_tick
done
assert_equal call_1 "$SF_PRESENT_TOOL_CURRENT"
[[ $published == *'before tool'* ]] || fail 'tool call preceded the final assistant row'
if sf_tui_transport_has_pending; then
  fail 'transport events remained after the tool frame'
fi

# A tool-only response has no assistant row to publish first.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=(
  '{"type":"_backend_request_start"}'
  '{"type":"message","role":"assistant","stop":"tool_calls","content":[{"type":"tool_call","id":"call_2","name":"shell","input":{"command":"true"}}]}'
)
sf_tui_heartbeat_tick
assert_equal call_2 "$SF_PRESENT_TOOL_CURRENT"
if sf_tui_transport_has_pending; then
  fail 'tool-only response paused for an empty frame'
fi

# Successful completion stages the FIFO head as the next ordinary user turn.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_add activity '' '' '' open
SF_PRESENT_STATE=working
SF_PRESENT_QUEUE=( first second )
SF_PRESENT_HANDOFF=()
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
sf_tui_exec_finish
assert_equal queued "$SF_PRESENT_STATE"
assert_equal first "$SF_PRESENT_SUBMITTED"
assert_equal second "$SF_PRESENT_QUEUE[1]"
assert_equal user "$SF_PRESENT_NODE_ROLE[-1]"
assert_equal first "$SF_PRESENT_NODE_BODY[-1]"

# Cancellation intent wins when signalling races with an already-completed exec.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=cancelling
SF_PRESENT_QUEUE=( speculative )
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
SF_TUI_TRANSPORT_EXIT_DETAIL=''
sf_tui_exec_finish
assert_equal idle "$SF_PRESENT_STATE"
assert_equal 0 "${#SF_PRESENT_QUEUE}"
assert_equal 'Cancelled.' "$SF_PRESENT_NODE_HEADING[-1]"
[[ $SF_PRESENT_NODE_BODY[-1] == *'Discarded 1 queued prompt.'* ]] ||
  fail 'cancelled completion did not report discarded queued prompts'

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
assert_equal 'Exec process failed.' "$SF_PRESENT_NODE_HEADING[-1]"
[[ $SF_PRESENT_NODE_BODY[-1] == *'backend failed'* ]] ||
  fail 'exec failure omitted process stderr'
[[ $SF_PRESENT_NODE_BODY[-1] == *'Discarded 1 queued prompt.'* ]] ||
  fail 'exec failure did not report discarded queued prompts'

# A decoded exec error survives authoritative recovery and takes precedence over
# the child process's generic nonzero exit.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=working
sf_tui_transport_reset
SF_TUI_TRANSPORT_LINES=(
  '{"type":"_turn_error","message":"backend emitted an invalid event stream"}'
  '{"type":"_turn_error","message":"cannot append session record: /tmp/recover.jsonl"}'
)
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=1
SF_TUI_TRANSPORT_EXIT_DETAIL='backend emitted an invalid event stream'
sf_tui_heartbeat_tick
assert_equal idle "$SF_PRESENT_STATE"
assert_equal 'Provider response invalid' "$SF_PRESENT_NODE_HEADING[-1]"
assert_equal $'backend emitted an invalid event stream\nSession failed: cannot append session record: /tmp/recover.jsonl' \
  "$SF_PRESENT_NODE_BODY[-1]"

# A terminated exec can replace a flushed and closed speculative assistant
# prefix during turn recovery. Chat resets that live tail and remains usable.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_PREFIX_VISIBLE=1
sf_tui_add message agent '' 'speculative streamed prefix'
SF_PRESENT_CURSOR='1:12'
SF_PRESENT_STATE=working
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=143
SF_TUI_TRANSPORT_EXIT_DETAIL=''
sf_tui_exec_finish
assert_equal idle "$SF_PRESENT_STATE"
assert_equal 1:0 "$SF_PRESENT_CURSOR"
assert_equal 'Exec process terminated.' "$SF_PRESENT_NODE_HEADING[-1]"
assert_equal 'Terminated by signal 15.' "$SF_PRESENT_NODE_BODY[-1]"
sf_tui_submit next
assert_equal submit "$REPLY"
assert_equal next "$SF_PRESENT_SUBMITTED"

# A renderer failure does not abort a successful turn. Completion reloads the
# durable transcript, reports the recovery, and clears the live-render latch.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event assistant_delta speculative
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=working
SF_PRESENT_RENDER_ERROR='Live rendering failed.'
SF_PRESENT_QUEUE=()
SF_PRESENT_HANDOFF=()
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
SF_TUI_TRANSPORT_EXIT_DETAIL=''
sf_tui_exec_finish
assert_equal idle "$SF_PRESENT_STATE"
assert_equal '' "$SF_PRESENT_RENDER_ERROR"
assert_equal 'Live rendering failed.' "$SF_PRESENT_NODE_HEADING[-1]"
assert_equal 'The completed turn was reloaded.' "$SF_PRESENT_NODE_BODY[-1]"
[[ ${(j:\n:)SF_PRESENT_NODE_BODY} != *speculative* ]] ||
  fail 'render recovery retained speculative presentation text'

# If the durable transcript cannot be reloaded, the chat stops instead of
# resuming from the invalid live presentation.
SF_PRESENT_SESSION="$tmp/missing.jsonl"
SF_PRESENT_STATE=working
SF_PRESENT_RENDER_ERROR='Live rendering failed.'
SF_TUI_TRANSPORT_EOF=1
SF_TUI_TRANSPORT_EXIT_STATUS=0
sf_tui_exec_finish
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal '' "$SF_PRESENT_RENDER_ERROR"

# A permission prompt cannot be reviewed safely without rendering. Stop the
# waiting child, reload durable state, and report discarded queued prompts.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_SESSION="$tmp/recover.jsonl"
SF_PRESENT_STATE=permission
SF_PRESENT_RENDER_ERROR='Live rendering failed.'
SF_PRESENT_QUEUE=( queued )
ZLE_CALLS=''
sf_tui_pre_redraw
assert_equal idle "$SF_PRESENT_STATE"
assert_equal '' "$SF_PRESENT_RENDER_ERROR"
assert_equal 0 "${#SF_PRESENT_QUEUE}"
assert_equal 'Live rendering failed.' "$SF_PRESENT_NODE_HEADING[-1]"
[[ $SF_PRESENT_NODE_BODY[-1] == *'Turn stopped before a permission decision.'* ]] ||
  fail 'permission render failure omitted its stop reason'
[[ $SF_PRESENT_NODE_BODY[-1] == *'Discarded 1 queued prompt.'* ]] ||
  fail 'permission render failure omitted its discarded queue'
[[ $ZLE_CALLS == *'turn stopped before permission.'* ]] ||
  fail 'permission render failure was not shown in ZLE'

SF_PRESENT_QUEUE=( one two )
sf_tui_discard_queue
assert_equal 'Discarded 2 queued prompts. Use ↑↓ keys to recover.' "$REPLY"
assert_equal 0 "${#SF_PRESENT_QUEUE}"
