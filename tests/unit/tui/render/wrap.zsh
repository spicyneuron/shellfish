#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh

rows() { REPLY="${(j:|:)SF_WRAP_ROWS}" }
spans() { REPLY="${(j:|:)SF_WRAP_SPANS}" }
consumed() { REPLY="${(j:,:)SF_WRAP_CONSUMED}" }

# A row breaks at a space, which is consumed: it belongs to no row and holds no
# display offset, so a span either side lands where the text actually sits.
sf_tui_wrap 5 'hello world' '' 3 9 'fg=2'
rows; assert_equal 'hello|world' "$REPLY"
spans; assert_equal '3 5 fg=2|0 3 fg=2' "$REPLY"
consumed; assert_equal '6,5' "$REPLY"

# Breaking at a leading space would emit a blank row instead of progressing, so
# a row with nothing before its space breaks mid-run instead.
sf_tui_wrap 3 ' hello' ''
rows; assert_equal ' he|llo' "$REPLY"

# A tab is not a break opportunity, and maps to every space emitted for it
# rather than to its single source character.
sf_tui_wrap 8 $'a\tb' '' 1 2 underline
rows; assert_equal "a${(l:7:)}|b" "$REPLY"
spans; assert_equal '1 8 underline|' "$REPLY"

# A newline ends its row and is consumed with it.
sf_tui_wrap 80 $'one\ntwo' ''
rows; assert_equal 'one|two' "$REPLY"
consumed; assert_equal '4,3' "$REPLY"

sf_tui_wrap 80 $'\nabc' ''
rows; assert_equal '|abc' "$REPLY"
consumed; assert_equal '1,3' "$REPLY"

# A prefix decorates every row and shifts display offsets without consuming
# source, so spans move by exactly its width.
sf_tui_wrap 80 abc '  ' 0 3 bold
rows; assert_equal '  abc' "$REPLY"
spans; assert_equal '2 5 bold' "$REPLY"

sf_tui_wrap 5 'hello world' '│ '
rows; assert_equal '│ hel|│ lo|│ wor|│ ld' "$REPLY"

# Offsets count characters rather than cells, so a wide character and a
# combining mark each keep one offset even though they occupy two cells and
# none. Escapes rather than literals: a combining mark is invisible in source.
sf_tui_wrap 80 $'ab\u754ce\u0301x' '' 2 5 standout
rows; assert_equal $'ab\u754ce\u0301x' "$REPLY"
spans; assert_equal '2 5 standout' "$REPLY"

# Cells still decide where the row ends: a combining mark adds no width, so it
# stays on the row with the character it marks rather than starting a new one.
sf_tui_wrap 4 $'abcd\u0301x' '' 3 5 underline
rows; assert_equal $'abcd\u0301|x' "$REPLY"
spans; assert_equal '3 5 underline|' "$REPLY"

# A wide character that does not fit moves down whole.
sf_tui_wrap 3 $'ab界' ''
rows; assert_equal 'ab|界' "$REPLY"

# Consumption always accounts for the whole text, so a caller can commit a row
# prefix and drop exactly what it covered.
sf_tui_wrap 5 'hello world one two' ''
consumed
integer total=0
for count in ${(s:,:)REPLY}; do (( total += count )); done
assert_equal 19 "$total"

# Every rejected call leaves nothing behind, so a caller that skips the return
# value reads no rows rather than the previous call's. A prefix that cannot fit
# its own row is rejected because it would otherwise never make progress, and a
# call missing its prefix would otherwise read its own arguments as spans.
reject() {
  sf_tui_wrap 80 kept ''
  if sf_tui_wrap "$@"; then
    fail "accepted an invalid call: $*"
  fi
  assert_equal 0 "${#SF_WRAP_ROWS}"
}
reject 2 abc '│ │ '
reject 0 abc ''
reject 5 'hello world'
reject 5 abc '' 1 2

# A character too wide for the space left overflows its row rather than
# wrapping forever against a row it can never fit.
sf_tui_wrap 1 $'界界' ''
rows; assert_equal $'界|界' "$REPLY"
sf_tui_wrap 3 $'界界' '│ '
rows; assert_equal $'│ 界|│ 界' "$REPLY"

# No content means no rows, even with chrome: whether a heading deserves a row
# of its own is the formatter's decision, not wrapping's. A trailing newline
# terminates its row rather than opening a blank one.
sf_tui_wrap 80 '' '  '
assert_equal 0 "${#SF_WRAP_ROWS}"
sf_tui_wrap 80 $'one\n' ''
rows; assert_equal one "$REPLY"
consumed; assert_equal 4 "$REPLY"
