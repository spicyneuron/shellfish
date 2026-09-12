#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh \
  libexec/tui/render/messages.zsh libexec/tui/render/hooks.zsh \
  libexec/tui/render/tools.zsh \
  libexec/tui/render/terminal.zsh libexec/tui/render/view.zsh \
  libexec/tui/transport.zsh libexec/tui/editor.zsh libexec/tui/controller.zsh

# Avoid the PTY worker.
sf_tui_heartbeat_arm() { return 0; }

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY='' POSTDISPLAY='' ZLE_CALL=''
typeset -g SF_PRESENT_SESSION=session.jsonl
typeset -g SF_PRESENT_STATE=idle
typeset -g SF_PRESENT_FOOTER=test/model
typeset -gi COLUMNS=80 LINES=10
typeset -ga ZLE_CALLS=()
typeset -gi ZLE_FAIL_INVALIDATE=0
zle() {
  ZLE_CALL="$*"
  ZLE_CALLS+=( "$*" )
  [[ $1 != -I ]] || (( ! ZLE_FAIL_INVALIDATE )) || return 1
}
sf_tui_answer_permission() {
  assert_equal approve "$1"
  BUFFER=draft
  CURSOR=3
}

# Submit prompts.
BUFFER=prompt
SF_PRESENT_DRAFT=prompt
SF_PRESENT_DRAFT_CURSOR=6
SF_PRESENT_DRAFT_SAVED=1
SF_PRESENT_ACTION=''
ZLE_CALL=''
sf_tui_accept
assert_equal submit "$SF_PRESENT_ACTION"
assert_equal prompt "$SF_PRESENT_SUBMITTED"
assert_equal accept-line "$ZLE_CALL"

# Clear drafts on interrupt.
BUFFER=draft
sf_tui_interrupt
assert_equal '' "$BUFFER"
assert_equal 0 "$CURSOR"
assert_equal -R "$ZLE_CALL"

# Quit after a second interrupt.
sf_tui_interrupt
assert_equal quit "$SF_PRESENT_ACTION"
assert_equal accept-line "$ZLE_CALL"
assert_equal 130 "$SF_PRESENT_EXIT_STATUS"

# Escape may prefix a longer key sequence.
SF_PRESENT_STATE=working
SF_PRESENT_ACTION=''
ZLE_CALL=''
sf_tui_escape
assert_equal working "$SF_PRESENT_STATE"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal -R "$ZLE_CALL"

# Keep queued turns on interrupt.
SF_PRESENT_STATE=queued
SF_PRESENT_ACTION=''
ZLE_CALLS=()
sf_tui_interrupt
assert_equal queued "$SF_PRESENT_STATE"
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal -R "$ZLE_CALLS[-1]"

# Quit while cancelling.
SF_PRESENT_STATE=cancelling
SF_PRESENT_ACTION=''
BUFFER=draft
ZLE_CALLS=()
sf_tui_interrupt
assert_equal draft "$BUFFER"
assert_equal quit "$SF_PRESENT_ACTION"
assert_equal 130 "$SF_PRESENT_EXIT_STATUS"
assert_equal accept-line "$ZLE_CALLS[-1]"

# Approve permissions on accept.
SF_PRESENT_STATE=permission
SF_PRESENT_PERMISSION_TOOL=shell
SF_PRESENT_PERMISSION_TEXT=$'pwd\n\nReason: host access'
BUFFER=a
CURSOR=1
sf_tui_accept
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
assert_equal -R "$ZLE_CALL"

# Map permission keys.
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

# Accept client commands.
SF_PRESENT_ACTION=''
SF_PRESENT_STATE=idle
BUFFER=/quit
sf_tui_accept
assert_equal quit "$SF_PRESENT_ACTION"

# Insert literal newlines.
LBUFFER=first
sf_tui_insert_newline
assert_equal $'first\n' "$LBUFFER"

# Manage queued prompts.
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

# Navigate history and multiline display rows.
SF_PRESENT_HISTORY=()
sf_tui_record_prompt first
sf_tui_record_prompt second
BUFFER=draft
CURSOR=3
sf_tui_up
assert_equal second "$BUFFER"
sf_tui_up
assert_equal first "$BUFFER"
sf_tui_down
sf_tui_down
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
BUFFER=${(l:70::x:)''}
CURSOR=70
COLUMNS=50
sf_tui_up
assert_equal 20 "$CURSOR"

# Bind documented editor keys.
bindkey -e
sf_tui_bind
[[ $(bindkey -M emacs '^M') == *sf_tui_accept ]]
[[ $(bindkey -M emacs $'\e[13;2u') == *sf_tui_insert_newline ]]
[[ $(bindkey -M sf-present $'\e[A') == *sf_tui_up ]]
[[ $(bindkey -M sf-present $'\e[B') == *sf_tui_down ]]
[[ $(bindkey -M sf-present '^C') == *sf_tui_interrupt ]]
[[ $(bindkey -M sf-present $'\e') == *sf_tui_escape ]]
[[ $(bindkey -M sf-permission a) == *sf_tui_insert ]]
[[ $(bindkey -M sf-permission d) == *sf_tui_insert ]]

# Stop after render failure.
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
BUFFER=/refresh
CURSOR=8
sf_tui_pre_redraw
assert_equal /refresh "$BUFFER"
assert_equal 8 "$CURSOR"
BUFFER=''
CURSOR=0
sf_tui_pre_redraw
sf_tui_line_init
sf_tui_heartbeat_tick
assert_equal 1 "$failed_repaints"
functions[sf_tui_repaint]=$saved_repaint
SF_PRESENT_STATE=idle
SF_PRESENT_ERROR=''

# Preserve settled rows when a terminal commit fails.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event user retained
SF_PRESENT_STATE=working
ZLE_FAIL_INVALIDATE=1
sf_tui_heartbeat_tick
ZLE_FAIL_INVALIDATE=0
assert_equal stopped "$SF_PRESENT_STATE"
[[ ${(F)SF_PRESENT_ROW_TEXT} == *retained* ]] ||
  fail 'failed terminal commit lost settled rows'

# Stop when a submitted prompt cannot be staged.
typeset saved_stage=$functions[sf_tui_terminal_stage]
sf_tui_terminal_stage() { return 1; }
SF_PRESENT_STATE=idle
SF_PRESENT_ERROR=''
SF_PRESENT_ACTION=''
BUFFER=unstageable
sf_tui_accept || fail 'accept reported a failure'
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal 'cannot stage chat rows' "$SF_PRESENT_ERROR"
functions[sf_tui_terminal_stage]=$saved_stage
