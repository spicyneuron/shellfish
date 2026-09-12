#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh

kinds() { REPLY="${(j:,:)SF_PRESENT_KIND}" }

# Formatter arrays must stay aligned.
aligned() {
  local name
  for name in SF_PRESENT_TEXT SF_PRESENT_DATA SF_PRESENT_ROLE SF_PRESENT_SECTION \
      SF_PRESENT_PRIOR SF_PRESENT_EMITTED; do
    (( ${#${(@P)name}} == ${#SF_PRESENT_KIND} )) ||
      fail "$name has ${#${(@P)name}} entries for ${#SF_PRESENT_KIND} formatters: $1"
  done
}

# Only the tail may be live.
sf_tui_reset
sf_tui_formatter_append message final || fail 'a final formatter was rejected'
sf_tui_formatter_append reasoning live || fail 'a live formatter was rejected'
assert_equal 2 "$SF_PRESENT_LIVE"
if sf_tui_formatter_append message; then
  fail 'appended past a live tail'
fi
sf_tui_formatter_settle || fail 'settling the live tail failed'
if sf_tui_formatter_settle; then
  fail 'settled without a live tail'
fi

# List changes preserve entry alignment and the live index.
sf_tui_reset
sf_tui_formatter_append message
SF_PRESENT_TEXT[REPLY]=first
sf_tui_formatter_role $REPLY user
sf_tui_formatter_append reasoning
SF_PRESENT_TEXT[REPLY]=second
sf_tui_formatter_append tool_call live
SF_PRESENT_TEXT[REPLY]=third
aligned 'after appending'
if sf_tui_formatter_drop 3; then
  fail 'dropped the live tail'
fi
sf_tui_formatter_drop 1 || fail 'dropping a formatted prefix failed'
aligned 'after dropping'
assert_equal 2 "$SF_PRESENT_LIVE"
kinds; assert_equal 'reasoning,tool_call' "$REPLY"
assert_equal 'second,third' "${(j:,:)SF_PRESENT_TEXT}"
sf_tui_formatter_retract || fail 'retracting the live tail failed'
aligned 'after retracting'
assert_equal second "${(j:,:)SF_PRESENT_TEXT}"
if sf_tui_formatter_retract; then
  fail 'retracted a settled formatter'
fi

# Retracting releases the live formatter's role and section.
sf_tui_reset
sf_tui_formatter_append message
sf_tui_formatter_role $REPLY user
assert_equal 1 "$SF_PRESENT_SECTION[1]"
sf_tui_formatter_append message
sf_tui_formatter_role $REPLY user
assert_equal '' "$SF_PRESENT_ROLE[2]"
if sf_tui_formatter_role 1 system; then
  fail 'claimed a second role for one formatter'
fi
sf_tui_formatter_append reasoning live
sf_tui_formatter_role $REPLY agent
assert_equal 2 "$SF_PRESENT_SECTION[3]"
sf_tui_formatter_drop 2
SF_PRESENT_EMITTED[1]=1
if sf_tui_formatter_retract; then
  fail 'retracted a formatter after it emitted rows'
fi
assert_equal 1 "$SF_PRESENT_LIVE"
SF_PRESENT_EMITTED[1]=0
sf_tui_formatter_retract
assert_equal user "$SF_PRESENT_LAST_ROLE"
assert_equal 1 "$SF_PRESENT_SECTION_ID"

# Unnumbered roles reset with formatter state.
sf_tui_reset
sf_tui_formatter_append message live
sf_tui_formatter_role $REPLY system
assert_equal '' "$SF_PRESENT_SECTION[1]"
assert_equal 0 "$SF_PRESENT_SECTION_ID"
sf_tui_reset
assert_equal 0 "${#SF_PRESENT_KIND}"
assert_equal 0 "$SF_PRESENT_LIVE"
assert_equal '' "$SF_PRESENT_LAST_ROLE"
