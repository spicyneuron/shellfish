#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh \
  libexec/tui/render/messages.zsh libexec/tui/render/terminal.zsh \
  libexec/tui/render/view.zsh

typeset -gi COLUMNS=80 LINES=10
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY=''
typeset -g SF_PRESENT_STATE=idle SF_PRESENT_FOOTER=''
typeset -g SF_PRESENT_PERMISSION_TOOL='' SF_PRESENT_PERMISSION_TEXT=''
typeset -g SF_PRESENT_PERMISSION_LANGUAGE=''
typeset -gi SF_PRESENT_PERMISSION_PREVIEW_LENGTH=0
typeset -ga SF_PRESENT_QUEUE=() SF_PRESENT_HISTORY=()
typeset -gi SF_PRESENT_HISTORY_NO=0

view() { sf_tui_transcript "$@" || fail 'rendering the transcript failed'; REPLY=$SF_PRESENT_VIEWPORT_TEXT }

# The first message of a role opens its rule, carrying the section number. The
# rule fills the width exactly so it meets the prompt divider below it.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event user hello
view 79 20
assert_equal $'─ user ──────────────────────────────────────────────────────────────────── 1 ─\n\nhello' "$REPLY"
assert_equal 79 "${#${REPLY%%$'\n'*}}"

# A second message in the same role opens no rule: the role is already in
# force, so only its own blank row separates it from what came before.
sf_tui_event user again
view 79 20
assert_equal $'─ user ──────────────────────────────────────────────────────────────────── 1 ─\n\nhello\n\nagain' "$REPLY"

# Entering a different role opens a numbered rule of its own.
sf_tui_reset
sf_tui_event user first
sf_tui_message_append agent reply
view 79 20
[[ $REPLY == *$'\n\n─ agent ─'*$' 2 ─\n\nreply' ]] || fail "agent rule: $REPLY"

# A rule that cannot fit its number stays a plain rule rather than a truncated
# one, and never overruns the width.
sf_tui_reset
sf_tui_event user hi
view 12 20
assert_equal $'─ user ─ 1 ─\n\nhi' "$REPLY"
view 10 20
assert_equal $'─ user ───\n\nhi' "$REPLY"
view 8 20
assert_equal $'─ user ─\n\nhi' "$REPLY"

# Spacing belongs to the formatter: leading blank lines are the previous turn's
# and a trailing run collapses, so a body is framed by exactly one blank row.
sf_tui_reset
sf_tui_event user $'\n\n  spaced  \n\n\n'
view 79 20
[[ $REPLY == *$'\n\n  spaced  ' ]] || fail "trimmed body: $REPLY"

# A complete record with nothing visible takes no entry at all, so it leaves
# neither a stray rule nor a gap in the section numbering.
sf_tui_reset
sf_tui_event user $'\n\n'
assert_equal 0 "${#SF_PRESENT_KIND}"
assert_equal 0 "$SF_PRESENT_SECTION_ID"
sf_tui_event user visible
assert_equal 1 "$SF_PRESENT_SECTION[1]"

# Wrapping is the formatter's, at the width repaint gives it, and rewrapping is
# all a resize costs.
sf_tui_reset
sf_tui_event user 'alpha beta gamma'
view 12 20
assert_equal $'─ user ─ 1 ─\n\nalpha beta\ngamma' "$REPLY"
view 8 20
assert_equal $'─ user ─\n\nalpha\nbeta\ngamma' "$REPLY"

# Only the last rows fit the budget, and the viewport keeps the tail.
sf_tui_reset
sf_tui_event user $'one\ntwo\nthree\nfour'
view 79 3
assert_equal $'two\nthree\nfour' "$REPLY"

# A complete record cannot change, so every row it renders is safe. The safe
# count covers all retained rows, not just the drawn ones: rows above the
# budget are precisely the ones on their way to scrollback.
sf_tui_reset
sf_tui_event user hello
sf_tui_transcript 79 20
assert_equal 3 "$SF_PRESENT_SAFE_PREFIX"
sf_tui_transcript 79 2
assert_equal 3 "$SF_PRESENT_SAFE_PREFIX"
assert_equal $'\nhello' "$SF_PRESENT_VIEWPORT_TEXT"

# Spans land on the text they claim, after the rows move into PREDISPLAY.
sf_tui_reset
SF_PRESENT_STYLE=( divider 'fg=8' section.user 'fg=1' muted 'fg=7' )
sf_tui_event user hello
sf_tui_transcript 79 20
typeset -a sliced=()
integer span
for (( span = 1; span <= ${#SF_PRESENT_VIEWPORT_HIGHLIGHTS}; span += 3 )); do
  sliced+=( "${SF_PRESENT_VIEWPORT_TEXT[SF_PRESENT_VIEWPORT_HIGHLIGHTS[span] + 1,SF_PRESENT_VIEWPORT_HIGHLIGHTS[span + 1]]}" )
done
[[ ${sliced[(r)user ]} == 'user ' ]] || fail "role title span: ${(j:|:)sliced}"
# The number sits inside the trailing divider, so its style has to be applied
# last or the divider would cover it.
assert_equal 1 "$sliced[-1]"

SF_PRESENT_STYLE=()
