#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh \
  libexec/tui/transport.zsh libexec/tui/editor.zsh libexec/tui/controller.zsh

# Avoid the PTY worker.
sf_tui_heartbeat_arm() { return 0; }

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY='' POSTDISPLAY='' ZLE_CALL=''
typeset -g SF_PRESENT_SESSION=session.jsonl
typeset -g SF_PRESENT_STATE=idle
typeset -g SF_PRESENT_FOOTER=test/model
typeset -gi COLUMNS=80 LINES=10
typeset -ga ZLE_CALLS=()
zle() {
  ZLE_CALL="$*"
  ZLE_CALLS+=( "$*" )
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

# Map permission keys and their numbers.
typeset -a permission_decisions=()
sf_tui_answer_permission() { permission_decisions+=( "$1" ); SF_PRESENT_STATE=working; }
for KEYS in a d x 1 2; do
  SF_PRESENT_STATE=permission
  WIDGET=self-insert
  sf_tui_input
done
assert_equal 'approve,deny,approve,deny' "${(j:,:)permission_decisions}"
assert_equal -R "$ZLE_CALL"

# Stop cancels the turn and restores the draft.
for KEYS in s 3; do
  SF_PRESENT_STATE=permission
  SF_PRESENT_PERMISSION_DRAFT=draft
  SF_PRESENT_PERMISSION_CURSOR=3
  BUFFER=''
  WIDGET=self-insert
  sf_tui_input
  assert_equal cancelling "$SF_PRESENT_STATE"
  assert_equal draft "$BUFFER"
done

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

# Permission state gates editing even when ZLE decoded the key beforehand.
SF_PRESENT_STATE=permission
BUFFER=''
ZLE_CALLS=()
for WIDGET in sf_tui_up sf_tui_down sf_tui_accept sf_tui_insert_newline \
    kill-word yank history-incremental-search-backward send-break; do
  sf_tui_input
done
assert_equal '' "$BUFFER"
assert_equal 0 "${#ZLE_CALLS}"
WIDGET=bracketed-paste
sf_tui_input
assert_equal '.bracketed-paste paste' "$ZLE_CALL"

# Idle and working states share normal editing.
WIDGET=self-insert
for SF_PRESENT_STATE in idle working; do
  sf_tui_input
  assert_equal '.self-insert --' "$ZLE_CALL"
done

# Wrapped kills keep appending to the cutbuffer.
SF_PRESENT_STATE=idle
ZLE_CALLS=()
WIDGET=backward-kill-word
sf_tui_input
assert_equal '-f kill,.backward-kill-word --' "${(j:,:)ZLE_CALLS}"

# Bind documented editor keys.
bindkey -e
ZLE_CALLS=()
sf_tui_bind
[[ $(bindkey -M sf-present '^M') == *sf_tui_accept ]]
[[ $(bindkey -M sf-present $'\e[13;2u') == *sf_tui_insert_newline ]]
[[ $(bindkey -M sf-present $'\e[A') == *sf_tui_up ]]
[[ $(bindkey -M sf-present $'\e[B') == *sf_tui_down ]]
[[ $(bindkey -M sf-present '^C') == *sf_tui_interrupt ]]
[[ $(bindkey -M sf-present $'\e') == *sf_tui_escape ]]
[[ $(bindkey -M sf-present x) == *self-insert ]]
[[ $(bindkey -M sf-present $'\xe9') == *self-insert ]]
[[ $(bindkey -M sf-present '^D') == *' delete-char' ]]
[[ $(bindkey -M sf-present $'\e[3~') == *' delete-char' ]]
[[ $(bindkey -M sf-present $'\e[H') == *beginning-of-line ]]
[[ $(bindkey -M sf-present $'\e[F') == *end-of-line ]]
[[ $(bindkey -M sf-present $'\e[1;5D') == *backward-word ]]
[[ $(bindkey -M sf-present $'\e[1;3C') == *forward-word ]]

# Inherit no editor commands beyond the explicit bindings.
for key in '^[x' '^[z' '^R' '^I' '^_' '^O'; do
  [[ $(bindkey -M sf-present $key) == *undefined-key ]] ||
    fail "$key is bound"
done
for binding in "${(@f)$(bindkey -M sf-present)}"; do
  widget=${binding##* }
  (( ${ZLE_CALLS[(Ie)-N $widget sf_tui_input]} )) ||
    fail "$widget bypassed input dispatch"
done

# Stop when pending chat rows cannot be staged on submission.
typeset saved_stage=$functions[sf_tui_terminal_stage]
typeset saved_repaint=$functions[sf_tui_repaint_checked]
sf_tui_terminal_stage() { return 1; }
sf_tui_repaint_checked() { SF_PRESENT_SAFE_ROWS=1; }
SF_PRESENT_STATE=idle
SF_PRESENT_ERROR=''
SF_PRESENT_ACTION=''
BUFFER=unstageable
sf_tui_accept || fail 'accept reported a failure'
assert_equal '' "$SF_PRESENT_ACTION"
assert_equal stopped "$SF_PRESENT_STATE"
assert_equal 'cannot stage chat rows' "$SF_PRESENT_ERROR"
functions[sf_tui_terminal_stage]=$saved_stage
functions[sf_tui_repaint_checked]=$saved_repaint
