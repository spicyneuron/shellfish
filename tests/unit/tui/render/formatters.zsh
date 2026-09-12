#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh

aligned() {
  local name
  for name in SF_PRESENT_TEXT SF_PRESENT_DATA SF_PRESENT_ROLE SF_PRESENT_SECTION \
      SF_PRESENT_PRIOR SF_PRESENT_EMITTED; do
    (( ${#${(@P)name}} == ${#SF_PRESENT_KIND} )) ||
      fail "$name is not aligned with formatter kinds: $1"
  done
}

# Only the formatter tail may be live.
sf_tui_reset
sf_tui_formatter_append message final || fail 'a final formatter was rejected'
sf_tui_formatter_append reasoning live || fail 'a live formatter was rejected'
assert_equal 2 "$SF_PRESENT_LIVE"
if sf_tui_formatter_append message; then
  fail 'appended past a live formatter'
fi
sf_tui_formatter_settle || fail 'settling the live formatter failed'
if sf_tui_formatter_settle; then
  fail 'settled without a live formatter'
fi

# Dropping and retracting keep parallel state aligned.
sf_tui_reset
sf_tui_formatter_append message
SF_PRESENT_TEXT[REPLY]=first
sf_tui_formatter_role $REPLY user
sf_tui_formatter_append reasoning
SF_PRESENT_TEXT[REPLY]=second
sf_tui_formatter_append tool_call live
SF_PRESENT_TEXT[REPLY]=third
aligned 'after append'
if sf_tui_formatter_drop 3; then
  fail 'dropped the live formatter'
fi
sf_tui_formatter_drop 1 || fail 'dropping a settled prefix failed'
aligned 'after drop'
assert_equal 2 "$SF_PRESENT_LIVE"
assert_equal 'reasoning,tool_call' "${(j:,:)SF_PRESENT_KIND}"
assert_equal 'second,third' "${(j:,:)SF_PRESENT_TEXT}"
sf_tui_formatter_retract || fail 'retracting the live formatter failed'
aligned 'after retract'
assert_equal second "${(j:,:)SF_PRESENT_TEXT}"

# Retracting a role restores section ownership.
sf_tui_reset
sf_tui_formatter_append message
sf_tui_formatter_role $REPLY user
sf_tui_formatter_append reasoning live
sf_tui_formatter_role $REPLY agent
assert_equal 2 "$SF_PRESENT_SECTION_ID"
sf_tui_formatter_drop 1
SF_PRESENT_EMITTED[1]=1
if sf_tui_formatter_retract; then
  fail 'retracted a formatter after it emitted rows'
fi
SF_PRESENT_EMITTED[1]=0
sf_tui_formatter_retract || fail 'retracting an uncommitted formatter failed'
assert_equal user "$SF_PRESENT_LAST_ROLE"
assert_equal 1 "$SF_PRESENT_SECTION_ID"
aligned 'after role retract'
