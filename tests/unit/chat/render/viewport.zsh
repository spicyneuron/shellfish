#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source chat/render/nodes.zsh chat/render/highlights.zsh chat/render/rows.zsh \
  chat/render/viewport.zsh

sf_chat_event user abcdef
sf_chat_viewport 80 2
assert_equal $'─ user ─────────────────────────────────────────────────────────────────────────\n' "$SF_PRESENT_VIEWPORT_TEXT"
assert_equal '─ user ─────────────────────────────────────────────────────────────────────────' "$SF_PRESENT_FLUSH_TEXT"
assert_equal 2:0 "$SF_PRESENT_FLUSH_CURSOR"
assert_equal 1 "$SF_PRESENT_FLUSH_ROWS"

sf_chat_viewport 80 1 2:0
assert_equal '' "$SF_PRESENT_FLUSH_TEXT"
assert_equal 2:1 "$SF_PRESENT_FLUSH_CURSOR"
assert_equal 1 "$SF_PRESENT_FLUSH_ROWS"

sf_chat_event assistant_delta $'first\npartial'
sf_chat_viewport 80 20 3:0
assert_equal $'\n─ agent ────────────────────────────────────────────────────────────────────────\n\nfirst\n⠃' "$SF_PRESENT_VIEWPORT_TEXT"
assert_equal $'\n─ agent ────────────────────────────────────────────────────────────────────────\n\nfirst' "$SF_PRESENT_FLUSH_TEXT"
assert_equal 4:7 "$SF_PRESENT_FLUSH_CURSOR"
assert_equal 4 "$SF_PRESENT_FLUSH_ROWS"

sf_chat_viewport 80 20 4:0
assert_equal $'\nfirst\n⠃' "$SF_PRESENT_VIEWPORT_TEXT"
assert_equal $'\nfirst' "$SF_PRESENT_FLUSH_TEXT"
assert_equal 4:7 "$SF_PRESENT_FLUSH_CURSOR"
assert_equal 2 "$SF_PRESENT_FLUSH_ROWS"

sf_chat_viewport 80 20 4:7
assert_equal ⠃ "$SF_PRESENT_VIEWPORT_TEXT"
assert_equal '' "$SF_PRESENT_FLUSH_TEXT"

# Repainting an open node at its exact source end shows only activity. It must
# not replay the full body or advance its cursor beyond the source length.
sf_chat_viewport 80 20 4:14
assert_equal ⠃ "$SF_PRESENT_VIEWPORT_TEXT"
assert_equal 4:14 "$SF_PRESENT_ROW_CURSOR[-1]"

sf_chat_event assistant_commit
sf_chat_viewport 80 20 4:7
assert_equal partial "$SF_PRESENT_FLUSH_TEXT"
assert_equal 5:0 "$SF_PRESENT_FLUSH_CURSOR"

sf_chat_reset
sf_chat_add message agent '' $'first\nsecond\npartial' open
sf_chat_set_frontier 1 6
sf_chat_viewport 80 20
assert_equal first "$SF_PRESENT_FLUSH_TEXT"
assert_equal 1:6 "$SF_PRESENT_FLUSH_CURSOR"

# Wrapping reports the source a filled visual row consumed, which is the only
# boundary a growing line may be highlighted to. It includes the discarded wrap
# whitespace, so releasing it settles the row rather than stranding it.
sf_chat_reset
sf_chat_add message agent '' 'hello world again' open
sf_chat_set_frontier 1 0
SF_PRESENT_HIGHLIGHT_ENABLED=1
SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[1]=markdown
sf_chat_viewport 5 2
assert_equal 0 "$SF_PRESENT_FLUSH_ROWS"
assert_equal 1 "$SF_PRESENT_ROW_BOUNDARY_NODE"
# The furthest filled row, so one scan releases every row the pass completed.
assert_equal 12 "$SF_PRESENT_ROW_BOUNDARY"
sf_chat_highlight_rows 1 "$SF_PRESENT_ROW_BOUNDARY" 100
assert_equal 1 "$SF_PRESENT_HIGHLIGHT_ADVANCED"
assert_equal 12 "$SF_PRESENT_NODE_FRONTIER[1]"
sf_chat_viewport 5 2
assert_equal hello "$SF_PRESENT_FLUSH_TEXT"
assert_equal 1:6 "$SF_PRESENT_FLUSH_CURSOR"

# A row ending inside an inline construct waits for the row that closes it,
# unless the held source has outgrown the caller's limit.
sf_chat_reset
sf_chat_add message agent '' '**hello world again' open
sf_chat_set_frontier 1 0
SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[1]=markdown
sf_chat_viewport 5 2
sf_chat_highlight_rows 1 "$SF_PRESENT_ROW_BOUNDARY" 100
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_ADVANCED"
assert_equal 0 "$SF_PRESENT_NODE_FRONTIER[1]"
sf_chat_highlight_rows 1 "$SF_PRESENT_ROW_BOUNDARY" 2
assert_equal 1 "$SF_PRESENT_HIGHLIGHT_ADVANCED"

# A closed construct releases the row it completes.
sf_chat_reset
sf_chat_add message agent '' '**hi** world again' open
sf_chat_set_frontier 1 0
SF_PRESENT_HIGHLIGHT_CACHE_LANGUAGE[1]=markdown
sf_chat_viewport 8 2
sf_chat_highlight_rows 1 "$SF_PRESENT_ROW_BOUNDARY" 100
assert_equal 1 "$SF_PRESENT_HIGHLIGHT_ADVANCED"

# Permission-held tool content is blocked by policy, not by its syntax
# frontier, and is not Markdown, so no boundary may be released for it.
sf_chat_reset
sf_chat_add tool_result agent '' 'permission text continues' open
SF_PRESENT_NODE_STATUS[1]=permission
sf_chat_set_frontier 1 0
sf_chat_viewport 5 2
assert_equal 0 "$SF_PRESENT_FLUSH_ROWS"
sf_chat_highlight_rows 1 5 100
assert_equal 0 "$SF_PRESENT_HIGHLIGHT_ADVANCED"

SF_PRESENT_ROW_TEXT=( alpha beta )
SF_PRESENT_ROW_HIGHLIGHTS=( '0 5 bold' '1 3 fg=2' )
sf_chat_collect_highlights 2
assert_equal '0,5,bold,7,9,fg=2' "${(j:,:)reply}"
SF_PRESENT_ROW_HIGHLIGHTS[2]='0 5 bold'
if sf_chat_collect_highlights 2; then
  fail 'accepted a highlight beyond its row text'
fi
