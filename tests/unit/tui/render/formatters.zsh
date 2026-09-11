#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh

kinds() { REPLY="${(j:,:)SF_PRESENT_KIND}" }

# Every parallel array must stay the same length, or an entry's fields drift
# apart from its kind. Used below against each operation that resizes the list,
# since that is where a field left out of sf_tui_formatter_keep would show.
aligned() {
  local name
  for name in SF_PRESENT_TEXT SF_PRESENT_DATA SF_PRESENT_ROLE SF_PRESENT_SECTION \
      SF_PRESENT_PRIOR; do
    (( ${#${(@P)name}} == ${#SF_PRESENT_KIND} )) ||
      fail "$name has ${#${(@P)name}} entries for ${#SF_PRESENT_KIND} formatters: $1"
  done
}

# Only the tail may be live, so a transition that forgets to settle fails
# rather than leaving two mutable entries behind.
sf_tui_reset
sf_tui_formatter_append message final || fail 'a final formatter was rejected'
assert_equal 1 "$REPLY"
assert_equal 0 "$SF_PRESENT_LIVE"
sf_tui_formatter_append reasoning live || fail 'a live formatter was rejected'
assert_equal 2 "$SF_PRESENT_LIVE"
if sf_tui_formatter_append message; then
  fail 'appended past a live tail'
fi
kinds; assert_equal 'message,reasoning' "$REPLY"
sf_tui_formatter_settle || fail 'settling the live tail failed'
assert_equal 0 "$SF_PRESENT_LIVE"
if sf_tui_formatter_settle; then
  fail 'settled without a live tail'
fi
sf_tui_formatter_append tool_call || fail 'appending after settling failed'
kinds; assert_equal 'message,reasoning,tool_call' "$REPLY"

if sf_tui_formatter_append '' final; then
  fail 'appended a formatter with no kind'
fi
if sf_tui_formatter_append message sometimes; then
  fail 'appended a formatter with an unknown mode'
fi

# The first formatter entering a role owns its rule. A later formatter in the
# same role owns nothing, so the rule is drawn once.
sf_tui_reset
sf_tui_formatter_append message
sf_tui_formatter_role $REPLY user
assert_equal user "$SF_PRESENT_ROLE[1]"
assert_equal 1 "$SF_PRESENT_SECTION[1]"
sf_tui_formatter_append message
sf_tui_formatter_role $REPLY user
assert_equal '' "$SF_PRESENT_ROLE[2]"
assert_equal '' "$SF_PRESENT_SECTION[2]"
sf_tui_formatter_append message
sf_tui_formatter_role $REPLY agent
assert_equal agent "$SF_PRESENT_ROLE[3]"
assert_equal 2 "$SF_PRESENT_SECTION[3]"

if sf_tui_formatter_role 3 system; then
  fail 'claimed a second role for one formatter'
fi
assert_equal 2 "$SF_PRESENT_SECTION_ID"
if sf_tui_formatter_role 99 user; then
  fail 'claimed a role for a formatter that does not exist'
fi
# Entry 2 owns no role, so this reaches the empty-role check rather than
# stopping at the guard above it.
if sf_tui_formatter_role 2 ''; then
  fail 'claimed an empty role'
fi

# A role outside the numbered pair takes no section number.
sf_tui_reset
sf_tui_formatter_append message
sf_tui_formatter_role $REPLY system
assert_equal system "$SF_PRESENT_ROLE[1]"
assert_equal '' "$SF_PRESENT_SECTION[1]"
assert_equal 0 "$SF_PRESENT_SECTION_ID"

# Retracting an empty formatter takes its role chrome with it and releases the
# section number, so the next section is numbered as though it never existed.
sf_tui_reset
sf_tui_formatter_append message
sf_tui_formatter_role $REPLY user
sf_tui_formatter_append reasoning live
sf_tui_formatter_role $REPLY agent
assert_equal 2 "$SF_PRESENT_SECTION_ID"
sf_tui_formatter_retract || fail 'retracting the live tail failed'
kinds; assert_equal message "$REPLY"
assert_equal 1 "$SF_PRESENT_SECTION_ID"
assert_equal user "$SF_PRESENT_LAST_ROLE"
sf_tui_formatter_append message live
sf_tui_formatter_role $REPLY agent
assert_equal 2 "$SF_PRESENT_SECTION[2]"

# Only the live tail retracts.
sf_tui_reset
sf_tui_formatter_append message
if sf_tui_formatter_retract; then
  fail 'retracted a settled formatter'
fi

# Retraction restores the role even after everything before it was committed
# and dropped, because each entry carries the role it displaced.
sf_tui_reset
sf_tui_formatter_append message
sf_tui_formatter_role $REPLY user
sf_tui_formatter_append reasoning live
sf_tui_formatter_role $REPLY agent
sf_tui_formatter_drop 1 || fail 'dropping a committed prefix failed'
assert_equal 1 "$SF_PRESENT_LIVE"
sf_tui_formatter_retract
assert_equal user "$SF_PRESENT_LAST_ROLE"
assert_equal 0 "${#SF_PRESENT_KIND}"

# Dropping shifts the live index rather than losing track of it, and never
# takes the live tail itself.
sf_tui_reset
sf_tui_formatter_append message
sf_tui_formatter_append reasoning
sf_tui_formatter_append tool_call live
assert_equal 3 "$SF_PRESENT_LIVE"
if sf_tui_formatter_drop 3; then
  fail 'dropped the live tail'
fi
sf_tui_formatter_drop 2 || fail 'dropping two committed formatters failed'
assert_equal 1 "$SF_PRESENT_LIVE"
kinds; assert_equal tool_call "$REPLY"
sf_tui_formatter_drop 0 || fail 'dropping nothing failed'
kinds; assert_equal tool_call "$REPLY"
if sf_tui_formatter_drop 2; then
  fail 'dropped more formatters than exist'
fi

# Content follows its own entry through every list operation. Dropping a
# committed prefix and retracting a live tail both have to move each field in
# step, which is what keeps a formatter's text attached to its kind.
sf_tui_reset
sf_tui_formatter_append message
SF_PRESENT_TEXT[REPLY]=first
sf_tui_formatter_append reasoning
SF_PRESENT_TEXT[REPLY]=second
sf_tui_formatter_append tool_call live
SF_PRESENT_TEXT[REPLY]=third
aligned 'after appending'
sf_tui_formatter_drop 1
aligned 'after dropping'
kinds; assert_equal 'reasoning,tool_call' "$REPLY"
assert_equal 'second,third' "${(j:,:)SF_PRESENT_TEXT}"
sf_tui_formatter_retract
aligned 'after retracting'
kinds; assert_equal reasoning "$REPLY"
assert_equal second "${(j:,:)SF_PRESENT_TEXT}"

# A reset clears the list and the role state together, so a rebuilt transcript
# numbers its sections from the start.
sf_tui_reset
sf_tui_formatter_append message live
sf_tui_formatter_role $REPLY user
sf_tui_reset
assert_equal 0 "${#SF_PRESENT_KIND}"
assert_equal 0 "$SF_PRESENT_LIVE"
assert_equal 0 "$SF_PRESENT_SECTION_ID"
assert_equal '' "$SF_PRESENT_LAST_ROLE"
