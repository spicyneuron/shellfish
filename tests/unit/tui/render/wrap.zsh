#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh

rows() { REPLY="${(j:|:)SF_WRAP_ROWS}" }
spans() { REPLY="${(j:|:)SF_WRAP_SPANS}" }
consumed() { REPLY="${(j:,:)SF_WRAP_CONSUMED}" }

# Break spaces are consumed without display offsets.
sf_tui_wrap 5 'hello world' '' 3 9 'fg=2'
rows; assert_equal 'hello|world' "$REPLY"
spans; assert_equal '3 5 fg=2|0 3 fg=2' "$REPLY"
consumed; assert_equal '6,5' "$REPLY"

# Leading spaces still make progress.
sf_tui_wrap 3 ' hello' ''
rows; assert_equal ' he|llo' "$REPLY"

# Tabs expand without creating break points.
sf_tui_wrap 8 $'a\tb' '' 1 2 underline
rows; assert_equal "a${(l:7:)}|b" "$REPLY"
spans; assert_equal '1 8 underline|' "$REPLY"

# Newlines are consumed with their row.
sf_tui_wrap 80 $'one\ntwo' ''
rows; assert_equal 'one|two' "$REPLY"
consumed; assert_equal '4,3' "$REPLY"

sf_tui_wrap 80 $'\nabc' ''
rows; assert_equal '|abc' "$REPLY"
consumed; assert_equal '1,3' "$REPLY"

# Prefixes shift spans without consuming source.
sf_tui_wrap 80 abc '  ' 0 3 bold
rows; assert_equal '  abc' "$REPLY"
spans; assert_equal '2 5 bold' "$REPLY"

sf_tui_wrap 5 'hello world' '│ '
rows; assert_equal '│ hel|│ lo|│ wor|│ ld' "$REPLY"

# Offsets count characters; wrapping counts cells.
sf_tui_wrap 80 $'ab\u754ce\u0301x' '' 2 5 standout
rows; assert_equal $'ab\u754ce\u0301x' "$REPLY"
spans; assert_equal '2 5 standout' "$REPLY"

# Combining marks add no width.
sf_tui_wrap 4 $'abcd\u0301x' '' 3 5 underline
rows; assert_equal $'abcd\u0301|x' "$REPLY"
spans; assert_equal '3 5 underline|' "$REPLY"

# Wide characters move down whole.
sf_tui_wrap 3 $'ab界' ''
rows; assert_equal 'ab|界' "$REPLY"

# Consumption accounts for all source characters.
sf_tui_wrap 5 'hello world one two' ''
consumed
integer total=0
for count in ${(s:,:)REPLY}; do (( total += count )); done
assert_equal 19 "$total"

# Rejected calls clear prior output.
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

# Oversized characters overflow their row.
sf_tui_wrap 1 $'界界' ''
rows; assert_equal $'界|界' "$REPLY"
sf_tui_wrap 3 $'界界' '│ '
rows; assert_equal $'│ 界|│ 界' "$REPLY"

# Empty content emits no rows.
sf_tui_wrap 80 '' '  '
assert_equal 0 "${#SF_WRAP_ROWS}"
sf_tui_wrap 80 $'one\n' ''
rows; assert_equal one "$REPLY"
consumed; assert_equal 4 "$REPLY"

# Overlapping spans advance independently across rows.
sf_tui_wrap 3 abcdef '' 0 6 base 0 2 early 3 6 late
spans; assert_equal '0 3 base 0 2 early|0 3 base 0 3 late' "$REPLY"
