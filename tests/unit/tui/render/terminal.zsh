#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/terminal.zsh
sf_test_tmp terminal

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY=old POSTDISPLAY=footer

# Restoring without a saved draft leaves the editor alone.
sf_tui_terminal_restore
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"

# Staging freezes the draft the rows will be committed above, and refuses to
# stage twice before a commit clears the pending rows.
SF_PRESENT_SAFE_TEXT=$'hello\n'
SF_PRESENT_SAFE_ROWS=1
SF_PRESENT_SAFE_HIGHLIGHTS=( 0 5 bold )
SF_PRESENT_SAFE_CONSUME=( '1:5:1:1' )
typeset -ga CONSUMED=()
sf_tui_formatter_consume() { CONSUMED+=( "$*" ); }
sf_tui_terminal_stage || fail 'staging safe rows failed'
assert_equal draft "$SF_PRESENT_DRAFT"
assert_equal 3 "$SF_PRESENT_DRAFT_CURSOR"
assert_equal '0 5 bold' "${(j: :)SF_PRESENT_PENDING_HIGHLIGHTS}"
assert_equal '1:5:1:1' "$SF_PRESENT_PENDING_CONSUME[1]"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
SF_PRESENT_SAFE_ROWS=1
if sf_tui_terminal_stage; then
  fail 'staged over uncommitted rows'
fi
SF_PRESENT_SAFE_ROWS=0

# Committing hands the rows to ZLE, clears the pending state, and records that
# something now sits above the prompt.
sf_tui_terminal_finish
assert_equal $'hello\n' "$PREDISPLAY"
assert_equal '' "$BUFFER"
assert_equal 0 "$SF_PRESENT_PENDING_ROWS"
assert_equal 1 "$SF_PRESENT_PREFIX_VISIBLE"
assert_equal '1 5 1 1' "$CONSUMED[1]"

sf_tui_terminal_restore
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
assert_equal 0 "$SF_PRESENT_DRAFT_SAVED"

# Nothing staged is not a failure; a commit with no pending rows is a no-op.
PREDISPLAY=kept
sf_tui_terminal_finish || fail 'an empty commit should succeed'
assert_equal kept "$PREDISPLAY"

# Forced synchronized-output cleanup emits the terminator once when cleanup
# paths converge.
SF_PRESENT_SYNC_ACTIVE=1
sf_tui_terminal_sync_end force >"$tmp/sync"
assert_equal 0 "$SF_PRESENT_SYNC_ACTIVE"
assert_equal $'\e[?2026l' "$(<"$tmp/sync")"
sf_tui_terminal_sync_end force >>"$tmp/sync"
assert_equal $'\e[?2026l' "$(<"$tmp/sync")"
