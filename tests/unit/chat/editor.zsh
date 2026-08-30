#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source chat/render/nodes.zsh chat/render/highlights.zsh chat/render/rows.zsh \
  chat/render/viewport.zsh chat/render/terminal.zsh chat/render/view.zsh chat/transport.zsh \
  chat/editor.zsh chat/controller.zsh

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY='' POSTDISPLAY='' ZLE_CALL=''
typeset -g SF_PRESENT_STATE=idle
typeset -g SF_PRESENT_FOOTER=test/model
typeset -gi COLUMNS=80 LINES=10
typeset -ga ZLE_CALLS=()
zle() { ZLE_CALL="$*"; ZLE_CALLS+=( "$*" ); }
sf_chat_answer_permission() {
  assert_equal approve "$1"
  BUFFER=draft
  CURSOR=3
}

sf_chat_event user hello
sf_chat_line_init
assert_equal epoch "$SF_PRESENT_ACTION"
assert_equal accept-line "$ZLE_CALL"
assert_equal draft "$SF_PRESENT_DRAFT"
assert_equal $'─ user ──────────────────────────────────────────────────────────────────── 1 ─\n\nhello\n\n───────────────────────────────────────────────────────────────────────────────\n❯ ' "$PREDISPLAY"

sf_chat_line_finish
assert_equal $'─ user ──────────────────────────────────────────────────────────────────── 1 ─\n\nhello' "$PREDISPLAY"
assert_equal '' "$POSTDISPLAY"
assert_equal 1:0 "$SF_PRESENT_CURSOR"
assert_equal 1 "$SF_PRESENT_SYNC_ACTIVE"
assert_equal -R "$ZLE_CALL"

ZLE_CALL=''
sf_chat_line_init
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
SF_PRESENT_LAST_ROLE=agent
ZLE_CALL=''
sf_chat_accept
assert_equal submit "$SF_PRESENT_ACTION"
assert_equal prompt "$SF_PRESENT_SUBMITTED"
assert_equal 1 "$SF_PRESENT_DRAFT_SAVED"
assert_equal accept-line "$ZLE_CALL"
sf_chat_line_finish
assert_equal $'\n─ user ──────────────────────────────────────────────────────────────────── 2 ─\n\nprompt' "$PREDISPLAY"
assert_equal '' "$BUFFER"
assert_equal -R "$ZLE_CALL"

BUFFER=draft
sf_chat_interrupt
assert_equal '' "$BUFFER"
assert_equal 0 "$CURSOR"
assert_equal -R "$ZLE_CALL"

sf_chat_interrupt
assert_equal quit "$SF_PRESENT_ACTION"
assert_equal accept-line "$ZLE_CALL"
assert_equal 130 "$SF_PRESENT_EXIT_STATUS"

SF_PRESENT_STATE=idle
SF_PRESENT_ACTION=''
BUFFER=draft
ZLE_CALL=''
KEYS=$'\e'
sf_chat_escape
assert_equal draft "$BUFFER"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal -R "$ZLE_CALL"

KEYS=$'\x18\t'
ZLE_CALLS=()
sf_chat_undefined_key
assert_equal $'-U \x18' "$ZLE_CALLS[-2]"
assert_equal $'-U \t' "$ZLE_CALLS[-1]"
KEYS=$'\x18\u00e9'
ZLE_CALLS=()
sf_chat_undefined_key
assert_equal $'-U \x18' "$ZLE_CALLS[-2]"
assert_equal $'-U \u00e9' "$ZLE_CALLS[-1]"
KEYS=$'\t'
sf_chat_undefined_key
assert_equal .undefined-key "$ZLE_CALL"

SF_PRESENT_STATE=queued
SF_PRESENT_ACTION=''
ZLE_CALLS=()
sf_chat_interrupt
assert_equal queued "$SF_PRESENT_STATE"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal -R "$ZLE_CALLS[-1]"

BUFFER=local
CURSOR=3
SF_PRESENT_DRAFT_SAVED=0
sf_chat_line_init
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
sf_chat_interrupt
assert_equal draft "$BUFFER"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal 1 "$SF_PRESENT_EXIT_PENDING"
assert_equal 130 "$SF_PRESENT_EXIT_STATUS"
assert_equal -R "$ZLE_CALLS[-1]"
SF_PRESENT_EXIT_PENDING=0

SF_PRESENT_STATE=permission
SF_PRESENT_PERMISSION_TOOL=shell
SF_PRESENT_PERMISSION_TEXT=$'pwd\n\nReason: host access'
BUFFER=a
CURSOR=1
sf_chat_accept
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
assert_equal -R "$ZLE_CALL"

typeset -a permission_decisions=()
sf_chat_answer_permission() { permission_decisions+=( "$1" ); SF_PRESENT_STATE=working; }
SF_PRESENT_STATE=permission
KEYS=a
sf_chat_insert
SF_PRESENT_STATE=permission
KEYS=d
sf_chat_insert
SF_PRESENT_STATE=permission
KEYS=x
sf_chat_insert
assert_equal 'approve,deny' "${(j:,:)permission_decisions}"
assert_equal -R "$ZLE_CALL"

SF_PRESENT_STATE=idle
SF_PRESENT_HISTORY=( history )
SF_PRESENT_HISTORY_DRAFT=current
SF_PRESENT_HISTORY_CURSOR=2
SF_PRESENT_HISTORY_NO=1
BUFFER=history
sf_chat_insert
BUFFER=historyX
sf_chat_pre_redraw
assert_equal historyX "$BUFFER"
assert_equal 0 "$SF_PRESENT_HISTORY_NO"
assert_equal .self-insert "$ZLE_CALL"

SF_PRESENT_ACTION=''
BUFFER=/quit
sf_chat_accept
assert_equal quit "$SF_PRESENT_ACTION"

LBUFFER=first
sf_chat_insert_newline
assert_equal $'first\n' "$LBUFFER"

# Pre-redraw runs after every widget, so an empty heartbeat queue always earns
# a replacement.
SF_PRESENT_STATE=working
KEYS_QUEUED_COUNT=0
PENDING=0
ZLE_CALLS=()
sf_chat_pre_redraw
assert_equal $'-U \x18' "$ZLE_CALLS[-1]"

# Input already waiting will wake ZLE on its own, and queuing a second tick
# behind it would double the heartbeat for every redraw that follows.
KEYS_QUEUED_COUNT=1
ZLE_CALLS=()
sf_chat_pre_redraw
assert_equal 0 "${#ZLE_CALLS}"
KEYS_QUEUED_COUNT=0
PENDING=1
ZLE_CALLS=()
sf_chat_pre_redraw
assert_equal 0 "${#ZLE_CALLS}"

SF_PRESENT_STATE=cancelling
KEYS_QUEUED_COUNT=0
PENDING=0
ZLE_CALLS=()
sf_chat_heartbeat_arm
assert_equal $'-U \x18' "$ZLE_CALLS[-1]"

sf_chat_reset
sf_chat_terminal_reset
sf_chat_add message agent '' $'one\ntwo\nthree\nfour\nfive\nsix'
SF_PRESENT_STATE=working
typeset -gi KEYS_QUEUED_COUNT=0 PENDING=0
COLUMNS=80
LINES=10
# No fd callback runs in this path. The queued heartbeat alone starts the epoch
# and line initialization drains the remaining bounded viewport.
ZLE_CALLS=()
sf_chat_heartbeat_arm
assert_equal $'-U \x18' "$ZLE_CALLS[-1]"
sf_chat_heartbeat_tick
assert_equal epoch "$SF_PRESENT_ACTION"
assert_equal accept-line "$ZLE_CALL"
assert_equal 4 "$SF_PRESENT_PENDING_ROWS"
assert_equal 9 "$SF_PRESENT_HEARTBEAT_REMAINING"
sf_chat_line_finish
sf_chat_line_init
assert_equal epoch "$SF_PRESENT_ACTION"
assert_equal accept-line "$ZLE_CALL"
sf_chat_line_finish
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"

# A heartbeat that finds only a mutable tail repaints and rearms itself rather
# than waiting for another fd notification. A stream that outruns its epochs
# ends its chain here rather than in line initialization, so this is where the
# held view has to be released; holding it spans the rest of the turn.
sf_chat_reset
sf_chat_terminal_reset
sf_chat_add message agent '' partial open
SF_PRESENT_STATE=working
SF_PRESENT_SYNC_ACTIVE=1
ZLE_CALLS=()
sf_chat_heartbeat_tick
assert_equal '-R' "$ZLE_CALLS[-2]"
assert_equal $'-U \x18' "$ZLE_CALLS[-1]"
assert_equal 0 "$SF_PRESENT_SYNC_ACTIVE"

# Timed heartbeats advance and repaint the activity pulse.
sf_chat_reset
sf_chat_terminal_reset
sf_chat_add activity '' '' '' open
SF_PRESENT_STATE=working
SF_PRESENT_HEARTBEAT_TIMEOUT=0
SF_PRESENT_HEARTBEAT_REMAINING=0
SF_PRESENT_ACTIVITY_FRAME=0
SF_PRESENT_ACTIVITY_TICKS=0
SF_PRESENT_ACTIVITY=${SF_PRESENT_ACTIVITY_FRAMES[1]}
typeset activity=$SF_PRESENT_ACTIVITY
sf_chat_heartbeat_tick
sf_chat_heartbeat_tick
[[ $SF_PRESENT_ACTIVITY != $activity ]] || fail 'activity frame did not advance'
[[ $PREDISPLAY == *$SF_PRESENT_ACTIVITY* ]] || fail 'activity frame was not repainted'

# Active-turn submits enter a transient FIFO and are available through history.
sf_chat_reset
sf_chat_terminal_reset
SF_PRESENT_STATE=working
SF_PRESENT_QUEUE=()
SF_PRESENT_HISTORY=()
COLUMNS=43
LINES=15
BUFFER=$'first queued\ncontinued'
CURSOR=${#BUFFER}
sf_chat_accept
assert_equal '' "$BUFFER"
assert_equal 1 "${#SF_PRESENT_QUEUE}"
assert_equal $'first queued\ncontinued' "$SF_PRESENT_QUEUE[1]"

BUFFER='second queued'
CURSOR=${#BUFFER}
sf_chat_accept
BUFFER='/queue drop 1'
CURSOR=${#BUFFER}
sf_chat_accept
assert_equal 'second queued' "$SF_PRESENT_QUEUE[1]"
BUFFER='/queue clear'
CURSOR=${#BUFFER}
sf_chat_accept
assert_equal 0 "${#SF_PRESENT_QUEUE}"

SF_PRESENT_HISTORY=()
sf_chat_record_prompt repeat
sf_chat_record_prompt repeat
sf_chat_record_prompt other
assert_equal 'repeat,other' "${(j:,:)SF_PRESENT_HISTORY}"
integer history_index
for history_index in {1..100}; do
  sf_chat_record_prompt "prompt $history_index"
done
assert_equal 100 "${#SF_PRESENT_HISTORY}"
assert_equal 'prompt 1' "$SF_PRESENT_HISTORY[1]"
assert_equal 'prompt 100' "$SF_PRESENT_HISTORY[-1]"
SF_PRESENT_HISTORY=()

# Vertical movement follows displayed rows from the two-column prompt.
COLUMNS=50
BUFFER=draft
CURSOR=5
sf_chat_down
assert_equal draft "$BUFFER"
assert_equal 5 "$CURSOR"

BUFFER=${(l:70::x:)''}
CURSOR=70
sf_chat_up
assert_equal 20 "$CURSOR"

bindkey -e
sf_chat_bind
[[ $(bindkey -M sf-present '^P') == *sf_chat_up ]] ||
  fail 'chat keymap does not bind vertical navigation'
[[ $(bindkey -M sf-present $'\e[A') == *sf_chat_up ]] ||
  fail 'chat keymap does not bind up-arrow navigation'
[[ $(bindkey -M sf-present $'\e[1;1A') == *sf_chat_up ]] ||
  fail 'chat keymap does not bind parameterized up-arrow navigation'
[[ $(bindkey -M sf-present $'\e[1;1B') == *sf_chat_down ]] ||
  fail 'chat keymap does not bind parameterized down-arrow navigation'
[[ $(bindkey -M sf-permission '^P') == *undefined-key ]] ||
  fail 'permission keymap permits vertical navigation'
[[ $(bindkey -M sf-present '^C') == *sf_chat_interrupt ]] ||
  fail 'chat keymap bypasses the interrupt widget'
[[ $(bindkey -M sf-present $'\e') == *sf_chat_escape ]] ||
  fail 'chat keymap does not interrupt on escape'
[[ $(bindkey -M sf-present $'\x18x') == *undefined-key ]] ||
  fail 'chat heartbeat suffix does not use the generic fallback'
[[ $(bindkey -M sf-permission '^C') == *sf_chat_interrupt ]] ||
  fail 'permission keymap bypasses the interrupt widget'
[[ $(bindkey -M sf-permission $'\e') == *sf_chat_escape ]] ||
  fail 'permission keymap bypasses the escape widget'

# A failed repaint cannot release the prompt as a submitted turn.
typeset saved_repaint=$functions[sf_chat_repaint]
sf_chat_repaint() { return 1; }
SF_PRESENT_STATE=idle
SF_PRESENT_ACTION=''
BUFFER=unstageable
if sf_chat_accept; then
  fail 'submit succeeded when repaint failed'
fi
assert_equal '' "$SF_PRESENT_ACTION"
functions[sf_chat_repaint]=$saved_repaint
