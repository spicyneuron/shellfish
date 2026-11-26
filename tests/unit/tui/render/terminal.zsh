#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh
sf_test_tmp terminal

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY=old POSTDISPLAY=footer

# Commit writes settled rows only, then restores the draft.
SF_TUI_SAFE_TEXT=$'hello\n'
SF_TUI_SAFE_ROWS=1
SF_TUI_SAFE_HIGHLIGHTS=( 0 5 bold )
typeset -ga CONSUMED=()
sf_tui_rows_consume() { CONSUMED+=( "$*" ); }
zle() {
  assert_equal $'hello\n' "$PREDISPLAY"
  assert_equal '' "$BUFFER"
  assert_equal 'P0 5 bold' "$region_highlight[1]"
  [[ $1 != -I || ${REJECT_INVALIDATE:-0} == 0 ]]
}
sf_tui_terminal_commit
assert_equal 0 "$SF_TUI_SAFE_ROWS"
assert_equal 1 "$SF_TUI_PREFIX_VISIBLE"
assert_equal 1 "$CONSUMED[1]"

assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"

# A failed invalidation does not consume any rows or steal the draft.
SF_TUI_SAFE_ROWS=1
if REJECT_INVALIDATE=1 sf_tui_terminal_commit; then
  fail 'commit accepted a failed invalidation'
fi
assert_equal 1 "$SF_TUI_SAFE_ROWS"
assert_equal 1 "${#CONSUMED}"
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"

# Forced sync cleanup emits one terminator.
SF_TUI_SYNC_ACTIVE=1
sf_tui_terminal_sync_end force >"$tmp/sync"
assert_equal 0 "$SF_TUI_SYNC_ACTIVE"
assert_equal $'\e[?2026l' "$(<"$tmp/sync")"
sf_tui_terminal_sync_end force >>"$tmp/sync"
assert_equal $'\e[?2026l' "$(<"$tmp/sync")"
