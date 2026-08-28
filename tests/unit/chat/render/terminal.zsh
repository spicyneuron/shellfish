#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source chat/render/nodes.zsh chat/render/highlights.zsh chat/render/rows.zsh \
  chat/render/viewport.zsh chat/render/terminal.zsh
sf_test_tmp terminal

typeset -g BUFFER=draft CURSOR=3 PREDISPLAY=old POSTDISPLAY=footer

sf_chat_terminal_restore
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"

sf_chat_event user hello
sf_chat_viewport 80 20 "$SF_PRESENT_CURSOR"
SF_PRESENT_FLUSH_HIGHLIGHTS=( 2 6 bold )
sf_chat_terminal_stage
assert_equal draft "$SF_PRESENT_DRAFT"
assert_equal 3 "$SF_PRESENT_DRAFT_CURSOR"
assert_equal '2,6,bold' "${(j:,:)SF_PRESENT_PENDING_HIGHLIGHTS}"
if sf_chat_terminal_stage; then
  fail 'overwrote a staged flush'
fi

sf_chat_terminal_finish
assert_equal $'─ user ─────────────────────────────────────────────────────────────────────────\n\nhello' "$PREDISPLAY"
assert_equal '' "$BUFFER"
assert_equal '' "$POSTDISPLAY"
assert_equal 1:0 "$SF_PRESENT_CURSOR"
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"

sf_chat_terminal_restore
assert_equal draft "$BUFFER"
assert_equal 3 "$CURSOR"
assert_equal 0 "${#SF_PRESENT_PENDING_HIGHLIGHTS}"

sf_chat_event assistant one
sf_chat_viewport 80 20 "$SF_PRESENT_CURSOR"
assert_equal $'\n─ agent ────────────────────────────────────────────────────────────────────────\n\none' "$SF_PRESENT_VIEWPORT_TEXT"

sf_chat_reset
sf_chat_terminal_reset
sf_chat_event user hello
sf_chat_viewport 80 1 2:0
sf_chat_terminal_stage
sf_chat_terminal_finish
assert_equal '' "$PREDISPLAY"
assert_equal 1:0 "$SF_PRESENT_CURSOR"
if sf_chat_terminal_stage; then
  fail 'staged a viewport without flushable rows'
fi
sf_chat_viewport 80 1 "$SF_PRESENT_CURSOR"
assert_equal '' "$SF_PRESENT_VIEWPORT_TEXT"

# Rebase the cursor repeatedly while pruning whole nodes and part of the final
# node. Each flushed row must appear exactly once.
sf_chat_reset
sf_chat_terminal_reset
BUFFER=''
CURSOR=0
sf_chat_event user hi
sf_chat_event assistant 'one two three four five six seven eight nine ten'
typeset drained=''
integer steps=0
while true; do
  sf_chat_viewport 12 3 "$SF_PRESENT_CURSOR"
  (( SF_PRESENT_FLUSH_ROWS )) || break
  sf_chat_terminal_stage
  sf_chat_terminal_finish
  drained+=$PREDISPLAY$'\n'
  (( ++steps <= 20 )) || fail 'pruned transcript did not finish draining'
done
(( steps > 1 )) || fail 'pruned transcript drained in one viewport'
assert_equal 0 "${#SF_PRESENT_NODE_TYPE}"
typeset token stripped
integer occurrences
for token in hi one two three four five six seven eight nine ten; do
  stripped=${(S)drained//$token/}
  occurrences=$(( (${#drained} - ${#stripped}) / ${#token} ))
  assert_equal 1 "$occurrences"
done
for token in '─ user ─' '─ agent ─'; do
  stripped=${(S)drained//$token/}
  occurrences=$(( (${#drained} - ${#stripped}) / ${#token} ))
  assert_equal 1 "$occurrences"
done

# Pruning a decorated heading preserves its width-independent tail cursor, so a
# resize cannot expose body rows beyond the flushed preview budget.
sf_chat_reset
sf_chat_terminal_reset
sf_chat_rows_config '{"tui":{"preview_lines_context":1}}'
sf_chat_section user
sf_chat_event context hook project $'alpha beta\ngamma\ndelta'
sf_chat_viewport 16 4 "$SF_PRESENT_CURSOR"
assert_equal '2:t:0:1' "$SF_PRESENT_FLUSH_CURSOR"
sf_chat_terminal_stage
sf_chat_terminal_finish
assert_equal '1:t:0:1' "$SF_PRESENT_CURSOR"
sf_chat_viewport 8 20 "$SF_PRESENT_CURSOR"
[[ $SF_PRESENT_VIEWPORT_TEXT != *gamma* && $SF_PRESENT_VIEWPORT_TEXT != *delta* ]] ||
  fail 'pruned preview cursor exposed hidden context after resize'

# Once a prefix is flushed, narrowing the terminal rewraps only its suffix.
sf_chat_reset
sf_chat_terminal_reset
sf_chat_add message user '' 'alpha beta gamma delta epsilon'
sf_chat_viewport 12 1 "$SF_PRESENT_CURSOR"
sf_chat_terminal_stage
sf_chat_terminal_finish
typeset flushed=$PREDISPLAY
assert_equal 'alpha beta' "$flushed"
sf_chat_viewport 8 20 "$SF_PRESENT_CURSOR"
[[ $SF_PRESENT_VIEWPORT_TEXT == *gamma*$'\n'delta$'\n'epsilon &&
    $SF_PRESENT_VIEWPORT_TEXT != *alpha* && $SF_PRESENT_VIEWPORT_TEXT != *beta* ]] ||
  fail 'resize rewrote the flushed prefix or lost its suffix'
assert_equal 'alpha beta' "$flushed"

# Same-node scrollback drops syntax spans behind the flushed source boundary
# while retaining absolute offsets for the visible suffix.
sf_chat_reset
sf_chat_terminal_reset
sf_chat_add message agent '' $'first\nsecond' open
sf_chat_set_frontier 1 6
SF_PRESENT_HIGHLIGHT_CACHE[1]='0 5 bold 6 12 fg=2'
SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[1]=markdown
SF_PRESENT_HIGHLIGHT_CACHE_START[1]=0
sf_chat_viewport 80 20 "$SF_PRESENT_CURSOR"
sf_chat_terminal_stage
sf_chat_terminal_finish
assert_equal 6 "$SF_PRESENT_HIGHLIGHT_CACHE_START[1]"
assert_equal '6 12 fg=2' "$SF_PRESENT_HIGHLIGHT_CACHE[1]"

# Forced synchronized-output cleanup emits the terminator once when cleanup
# paths converge.
SF_PRESENT_SYNC_ACTIVE=1
sf_chat_terminal_sync_end force >"$tmp/sync"
assert_equal 0 "$SF_PRESENT_SYNC_ACTIVE"
assert_equal $'\e[?2026l' "$(<"$tmp/sync")"
sf_chat_terminal_sync_end force >>"$tmp/sync"
assert_equal $'\e[?2026l' "$(<"$tmp/sync")"
