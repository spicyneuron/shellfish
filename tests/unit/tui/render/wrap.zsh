#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh

rows() { REPLY="${(j:|:)SF_WRAP_ROWS}" }

# Break spaces do not appear on either wrapped row.
sf_tui_wrap 5 'hello world' ''
rows; assert_equal 'hello|world' "$REPLY"

# Tabs expand without creating break points.
sf_tui_wrap 8 $'a\tb' ''
rows; assert_equal "a${(l:7:)}|b" "$REPLY"

# Newlines create rows.
sf_tui_wrap 80 $'one\ntwo' ''
rows; assert_equal 'one|two' "$REPLY"

# Prefixes repeat on wrapped rows.
sf_tui_wrap 80 abc '  '
rows; assert_equal '  abc' "$REPLY"

sf_tui_wrap 5 'hello world' '│ '
rows; assert_equal '│ hel|│ lo|│ wor|│ ld' "$REPLY"

# Wrapping counts terminal cells rather than characters.
sf_tui_wrap 80 $'ab\u754ce\u0301x' ''
rows; assert_equal $'ab\u754ce\u0301x' "$REPLY"

# Combining marks add no width.
sf_tui_wrap 4 $'abcd\u0301x' ''
rows; assert_equal $'abcd\u0301|x' "$REPLY"

# Wide characters move down whole.
sf_tui_wrap 3 $'ab界' ''
rows; assert_equal 'ab|界' "$REPLY"

# Oversized characters overflow their row.
sf_tui_wrap 1 $'界界' ''
rows; assert_equal $'界|界' "$REPLY"
sf_tui_wrap 3 $'界界' '│ '
rows; assert_equal $'│ 界|│ 界' "$REPLY"

sf_tui_wrap 80 $'one\n' ''
rows; assert_equal one "$REPLY"

# A limited wrap keeps one extra row to detect hidden output.
sf_tui_wrap -L 2 80 $'one\ntwo\nthree' ''
rows; assert_equal 'one|two' "$REPLY"
sf_tui_wrap -L 2 5 'hello world again' ''
rows; assert_equal 'hello|world' "$REPLY"
sf_tui_wrap -L 2 80 $'one\ntwo' ''
rows; assert_equal 'one|two' "$REPLY"
