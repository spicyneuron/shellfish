#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/terminal.zsh
sf_test_tmp terminal

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY=old POSTDISPLAY=footer

# Staging saves the draft until pending rows commit.
SF_PRESENT_SAFE_TEXT=$'hello\n'
SF_PRESENT_SAFE_ROWS=1
SF_PRESENT_SAFE_HIGHLIGHTS=( 0 5 bold )
typeset -ga CONSUMED=()
sf_tui_rows_consume() { CONSUMED+=( "$*" ); }
sf_tui_terminal_stage || fail 'staging safe rows failed'
assert_equal draft "$SF_PRESENT_DRAFT"
assert_equal 3 "$SF_PRESENT_DRAFT_CURSOR"

# Finish commits staged rows.
sf_tui_terminal_finish
assert_equal $'hello\n' "$PREDISPLAY"
assert_equal '' "$BUFFER"
assert_equal 0 "$SF_PRESENT_PENDING_ROWS"
assert_equal 1 "$SF_PRESENT_PREFIX_VISIBLE"
assert_equal 1 "$CONSUMED[1]"

sf_tui_terminal_restore
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
assert_equal 0 "$SF_PRESENT_DRAFT_SAVED"

# Forced sync cleanup emits one terminator.
SF_PRESENT_SYNC_ACTIVE=1
sf_tui_terminal_sync_end force >"$tmp/sync"
assert_equal 0 "$SF_PRESENT_SYNC_ACTIVE"
assert_equal $'\e[?2026l' "$(<"$tmp/sync")"
sf_tui_terminal_sync_end force >>"$tmp/sync"
assert_equal $'\e[?2026l' "$(<"$tmp/sync")"
