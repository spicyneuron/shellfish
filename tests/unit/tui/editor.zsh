#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh \
  libexec/tui/render/messages.zsh libexec/tui/render/hooks.zsh \
  libexec/tui/render/tools.zsh \
  libexec/tui/render/terminal.zsh libexec/tui/render/view.zsh \
  libexec/tui/transport.zsh libexec/tui/editor.zsh libexec/tui/controller.zsh

# Keep unit tests PTY-free; the real worker lifecycle is covered by tests/pty.
sf_tui_heartbeat_arm() { return 0; }

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY='' POSTDISPLAY='' ZLE_CALL=''
# Turn events are only legal once a session exists.
typeset -g SF_PRESENT_SESSION=session.jsonl
typeset -g SF_PRESENT_STATE=idle
typeset -g SF_PRESENT_FOOTER=test/model
typeset -gi COLUMNS=80 LINES=10
typeset -ga ZLE_CALLS=()
typeset -g COMMITTED=''
typeset -gi ZLE_ACCEPT_SYNC=0 ZLE_FAIL_ACCEPT=0 ZLE_FAIL_INVALIDATE=0
# A commit hands its rows to the terminal by leaving them drawn when the display
# is invalidated, so that is the moment worth capturing.
zle() {
  ZLE_CALL="$*"
  ZLE_CALLS+=( "$*" )
  [[ $1 != -I ]] || COMMITTED=$PREDISPLAY$BUFFER$POSTDISPLAY
  [[ $1 != -I ]] || (( ! ZLE_FAIL_INVALIDATE )) || return 1
  [[ $1 != accept-line ]] || ZLE_ACCEPT_SYNC=$SF_PRESENT_SYNC_ACTIVE
  [[ $1 != accept-line ]] || (( ! ZLE_FAIL_ACCEPT )) || return 1
}
sf_tui_answer_permission() {
  assert_equal approve "$1"
  BUFFER=draft
  CURSOR=3
}

# Safe rows found while idle commit through the epoch accept-line, which saves
# the draft, hands exactly those rows to the terminal, and leaves no chrome.
sf_tui_event user hello
sf_tui_line_init
assert_equal epoch "$SF_PRESENT_ACTION"
assert_equal accept-line "$ZLE_CALL"
assert_equal draft "$SF_PRESENT_DRAFT"

sf_tui_line_finish
[[ $PREDISPLAY == *$'─ user '*$' 1 ─\n\nhello' ]] ||
  fail "epoch did not commit the user formatter: $PREDISPLAY"
assert_equal '' "$POSTDISPLAY"
assert_equal 0 "$SF_PRESENT_PENDING_ROWS"
assert_equal 1 "$SF_PRESENT_SYNC_ACTIVE"
assert_equal -R "$ZLE_CALL"

ZLE_CALL=''
sf_tui_line_init
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
assert_equal $'\n───────────────────────────────────────────────────────────────────────────────\n❯ ' "$PREDISPLAY"
assert_equal $'\n───────────────────────────────────────────────────────────────────────────────\ntest/model' "$POSTDISPLAY"
assert_equal 0 "$SF_PRESENT_SYNC_ACTIVE"
assert_equal -R "$ZLE_CALL"

BUFFER=prompt
SF_PRESENT_DRAFT=prompt
SF_PRESENT_DRAFT_CURSOR=6
SF_PRESENT_DRAFT_SAVED=1
SF_PRESENT_ACTION=''
ZLE_CALL=''
ZLE_ACCEPT_SYNC=0
# An accepted prompt commits the rows the repaint staged for it.
sf_tui_accept
assert_equal submit "$SF_PRESENT_ACTION"
assert_equal prompt "$SF_PRESENT_SUBMITTED"
assert_equal 1 "$SF_PRESENT_DRAFT_SAVED"
assert_equal accept-line "$ZLE_CALL"
assert_equal 1 "$ZLE_ACCEPT_SYNC"
sf_tui_line_finish
assert_equal $'\nprompt' "$PREDISPLAY"
assert_equal '' "$BUFFER"
assert_equal -R "$ZLE_CALL"

BUFFER=draft
sf_tui_interrupt
assert_equal '' "$BUFFER"
assert_equal 0 "$CURSOR"
assert_equal -R "$ZLE_CALL"

sf_tui_interrupt
assert_equal quit "$SF_PRESENT_ACTION"
assert_equal accept-line "$ZLE_CALL"
assert_equal 130 "$SF_PRESENT_EXIT_STATUS"

# Escape never cancels: it cannot be told from an arrow key without an idle
# window, and a streaming turn never provides one.
SF_PRESENT_STATE=working
SF_PRESENT_ACTION=''
ZLE_CALL=''
sf_tui_escape
assert_equal working "$SF_PRESENT_STATE"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal -R "$ZLE_CALL"

SF_PRESENT_STATE=working
SF_PRESENT_PENDING_ROWS=1
ZLE_CALLS=()
sf_tui_pre_redraw
assert_equal 0 "${#ZLE_CALLS}"
SF_PRESENT_PENDING_ROWS=0

SF_PRESENT_STATE=queued
SF_PRESENT_ACTION=''
ZLE_CALLS=()
sf_tui_interrupt
assert_equal queued "$SF_PRESENT_STATE"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal -R "$ZLE_CALLS[-1]"

BUFFER=local
CURSOR=3
SF_PRESENT_DRAFT_SAVED=0
sf_tui_line_init
assert_equal submit "$SF_PRESENT_ACTION"
assert_equal local "$SF_PRESENT_DRAFT"
assert_equal 3 "$SF_PRESENT_DRAFT_CURSOR"
assert_equal 1 "$SF_PRESENT_DRAFT_SAVED"
assert_equal accept-line "$ZLE_CALLS[-1]"
SF_PRESENT_DRAFT=''
SF_PRESENT_DRAFT_CURSOR=0
SF_PRESENT_DRAFT_SAVED=0

SF_PRESENT_STATE=cancelling
SF_PRESENT_ACTION=''
BUFFER=draft
ZLE_CALLS=()
sf_tui_interrupt
assert_equal draft "$BUFFER"
assert_equal quit "$SF_PRESENT_ACTION"
assert_equal 130 "$SF_PRESENT_EXIT_STATUS"
assert_equal accept-line "$ZLE_CALLS[-1]"

SF_PRESENT_STATE=permission
SF_PRESENT_PERMISSION_TOOL=shell
SF_PRESENT_PERMISSION_TEXT=$'pwd\n\nReason: host access'
BUFFER=a
CURSOR=1
sf_tui_accept
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
assert_equal -R "$ZLE_CALL"

typeset -a permission_decisions=()
sf_tui_answer_permission() { permission_decisions+=( "$1" ); SF_PRESENT_STATE=working; }
SF_PRESENT_STATE=permission
KEYS=a
sf_tui_insert
SF_PRESENT_STATE=permission
KEYS=d
sf_tui_insert
SF_PRESENT_STATE=permission
KEYS=x
sf_tui_insert
assert_equal 'approve,deny' "${(j:,:)permission_decisions}"
assert_equal -R "$ZLE_CALL"

SF_PRESENT_STATE=idle
SF_PRESENT_HISTORY=( history )
SF_PRESENT_HISTORY_DRAFT=current
SF_PRESENT_HISTORY_CURSOR=2
SF_PRESENT_HISTORY_NO=1
BUFFER=history
sf_tui_insert
BUFFER=historyX
sf_tui_pre_redraw
assert_equal historyX "$BUFFER"
assert_equal 0 "$SF_PRESENT_HISTORY_NO"
assert_equal .self-insert "$ZLE_CALL"

SF_PRESENT_ACTION=''
BUFFER=/quit
sf_tui_accept
assert_equal quit "$SF_PRESENT_ACTION"

LBUFFER=first
sf_tui_insert_newline
assert_equal $'first\n' "$LBUFFER"

sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_STATE=working
SF_PRESENT_ACTION=''
typeset -gi KEYS_QUEUED_COUNT=0 PENDING=0
COLUMNS=80
LINES=10
# Safe rows found during a turn commit through the descriptor mechanism, which
# restores the draft, stays in the active editor, and spills no editor chrome.
BUFFER=draft
CURSOR=3
ZLE_CALLS=()
COMMITTED=''
sf_tui_event user $'one\ntwo'
sf_tui_heartbeat_tick
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal 0 "$SF_PRESENT_PENDING_ROWS"
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
[[ $COMMITTED == *one* ]] || fail 'heartbeat did not commit the safe rows'
[[ $COMMITTED != *❯* && $COMMITTED != *test/model* ]] ||
  fail 'heartbeat committed editor chrome to scrollback'
[[ ${(j: :)ZLE_CALLS} != *accept-line* ]] ||
  fail 'descriptor heartbeat left the active editor'

# Neither commit mechanism consumes formatter content when ZLE rejects the
# operation. The stopped view remains available without retrying that content.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event user retained
SF_PRESENT_STATE=working
ZLE_FAIL_INVALIDATE=1
sf_tui_heartbeat_tick
ZLE_FAIL_INVALIDATE=0
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal retained "$SF_PRESENT_TEXT[1]"

sf_tui_reset
sf_tui_terminal_reset
sf_tui_event user retained
SF_PRESENT_STATE=idle
SF_PRESENT_ERROR=''
ZLE_FAIL_ACCEPT=1
sf_tui_line_init
ZLE_FAIL_ACCEPT=0
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal retained "$SF_PRESENT_TEXT[1]"
SF_PRESENT_STATE=idle
SF_PRESENT_ERROR=''

# A heartbeat that finds no safe rows repaints and releases the synchronized
# update rather than holding it across the rest of the turn.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_STATE=working
SF_PRESENT_SYNC_ACTIVE=1
ZLE_CALLS=()
sf_tui_heartbeat_tick
assert_equal 1 "${#ZLE_CALLS}"
assert_equal '-R' "$ZLE_CALLS[-1]"
assert_equal 0 "$SF_PRESENT_SYNC_ACTIVE"

# Each heartbeat advances the activity pulse.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_STATE=working
SF_PRESENT_ACTIVITY_FRAME=0
SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[1]}
typeset activity=$SF_PRESENT_ACTIVITY
sf_tui_heartbeat_tick
[[ $SF_PRESENT_ACTIVITY != $activity ]] || fail 'activity frame did not advance'

# Active-turn submits enter a transient FIFO and are available through history.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_STATE=working
SF_PRESENT_QUEUE=()
SF_PRESENT_HISTORY=()
COLUMNS=43
LINES=15
BUFFER=$'first queued\ncontinued'
CURSOR=${#BUFFER}
sf_tui_accept
assert_equal '' "$BUFFER"
assert_equal 1 "${#SF_PRESENT_QUEUE}"
assert_equal $'first queued\ncontinued' "$SF_PRESENT_QUEUE[1]"

BUFFER='second queued'
CURSOR=${#BUFFER}
sf_tui_accept
BUFFER='/queue drop 1'
CURSOR=${#BUFFER}
sf_tui_accept
assert_equal 'second queued' "$SF_PRESENT_QUEUE[1]"
BUFFER='/queue clear'
CURSOR=${#BUFFER}
sf_tui_accept
assert_equal 0 "${#SF_PRESENT_QUEUE}"

SF_PRESENT_HISTORY=()
sf_tui_record_prompt repeat
sf_tui_record_prompt repeat
sf_tui_record_prompt other
assert_equal 'repeat,other' "${(j:,:)SF_PRESENT_HISTORY}"
integer history_index
for history_index in {1..100}; do
  sf_tui_record_prompt "prompt $history_index"
done
assert_equal 100 "${#SF_PRESENT_HISTORY}"
assert_equal 'prompt 1' "$SF_PRESENT_HISTORY[1]"
assert_equal 'prompt 100' "$SF_PRESENT_HISTORY[-1]"
SF_PRESENT_HISTORY=()

# Vertical movement follows displayed rows from the two-column prompt.
COLUMNS=50
BUFFER=draft
CURSOR=5
sf_tui_down
assert_equal draft "$BUFFER"
assert_equal 5 "$CURSOR"

BUFFER=${(l:70::x:)''}
CURSOR=70
sf_tui_up
assert_equal 20 "$CURSOR"

bindkey -e
sf_tui_bind
[[ $(bindkey -M sf-present '^P') == *sf_tui_up ]] ||
  fail 'chat keymap does not bind vertical navigation'
[[ $(bindkey -M sf-present $'\e[A') == *sf_tui_up ]] ||
  fail 'chat keymap does not bind up-arrow navigation'
[[ $(bindkey -M sf-present $'\e[1;1A') == *sf_tui_up ]] ||
  fail 'chat keymap does not bind parameterized up-arrow navigation'
[[ $(bindkey -M sf-present $'\e[1;1B') == *sf_tui_down ]] ||
  fail 'chat keymap does not bind parameterized down-arrow navigation'
[[ $(bindkey -M sf-present $'\e[3;5~') == *kill-word ]] ||
  fail 'chat keymap does not bind control-delete'
[[ $(bindkey -M sf-permission '^P') == *undefined-key ]] ||
  fail 'permission keymap permits vertical navigation'
[[ $(bindkey -M sf-present '^C') == *sf_tui_interrupt ]] ||
  fail 'chat keymap bypasses the interrupt widget'
# Escape stays bound to an inert widget: unbound, it is a bare prefix that
# leaves the editor waiting for a sequence that never arrives, and the next key
# then completes a meta binding instead.
[[ $(bindkey -M sf-present $'\e') == *sf_tui_escape ]] ||
  fail 'chat keymap leaves escape an unresolved prefix'
[[ $(bindkey -M sf-present $'\x18') != *sf_tui_heartbeat* ]] ||
  fail 'chat keymap reserves control-X for its heartbeat'
[[ $(bindkey -M sf-permission '^C') == *sf_tui_interrupt ]] ||
  fail 'permission keymap bypasses the interrupt widget'
[[ $(bindkey -M sf-permission $'\e') == *sf_tui_escape ]] ||
  fail 'permission keymap leaves escape an unresolved prefix'

# A repaint failure stops the chat: the renderer is never called again, nothing
# partial is staged, and the stopped view offers the durable session instead.
typeset saved_repaint=$functions[sf_tui_repaint]
typeset -gi failed_repaints=0
sf_tui_repaint() {
  (( ++failed_repaints ))
  SF_PRESENT_SAFE_ROWS=3
  return 1
}
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event assistant_message_delta 0 before
SF_PRESENT_SESSION=/tmp/stopped.jsonl
SF_PRESENT_STATE=working
SF_TUI_TRANSPORT_EVENTS=( assistant_message_delta 0 after '' '' '' '' )
SF_TUI_TRANSPORT_EOF=0
KEYS_QUEUED_COUNT=0
PENDING=0
ZLE_CALLS=()
sf_tui_heartbeat_tick
assert_equal 1 "$failed_repaints"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
assert_equal 0 "$SF_PRESENT_PENDING_ROWS"
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal 'cannot render chat' "$SF_PRESENT_ERROR"
[[ $PREDISPLAY == *'cannot render chat'* ]] ||
  fail 'the stopped view did not report the render failure'
[[ $PREDISPLAY == *'/refresh'* && $PREDISPLAY == *'/quit'* ]] ||
  fail 'the stopped view did not say which prompts it accepts'
# The editor still edits, so the commands it names can actually be typed.
BUFFER=/refresh
CURSOR=8
sf_tui_pre_redraw
assert_equal /refresh "$BUFFER"
assert_equal 8 "$CURSOR"
BUFFER=''
CURSOR=0
# Nothing reaches the failed renderer again, whatever else the editor does.
sf_tui_pre_redraw
sf_tui_line_init
sf_tui_heartbeat_tick
assert_equal 1 "$failed_repaints"
functions[sf_tui_repaint]=$saved_repaint
SF_PRESENT_STATE=idle
SF_PRESENT_ERROR=''

# A failed repaint or terminal stage stops instead of releasing the prompt.
sf_tui_reset
sf_tui_terminal_reset
saved_repaint=$functions[sf_tui_repaint]
sf_tui_repaint() { return 1; }
SF_PRESENT_STATE=idle
SF_PRESENT_ACTION=''
BUFFER=unstageable
sf_tui_accept || fail "accept reported a failure"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal stopped "$SF_PRESENT_STATE"
functions[sf_tui_repaint]=$saved_repaint
SF_PRESENT_STATE=idle

saved_stage=$functions[sf_tui_terminal_stage]
sf_tui_terminal_stage() { return 1; }
BUFFER=unstageable
sf_tui_accept || fail "accept reported a failure"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal 'cannot stage chat rows' "$SF_PRESENT_ERROR"
functions[sf_tui_terminal_stage]=$saved_stage
SF_PRESENT_STATE=idle
SF_PRESENT_ERROR=''
