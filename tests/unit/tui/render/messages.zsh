#!/usr/bin/env zsh

# Message and reasoning presentation. Actions arrive from the projector; rows
# are the atomic unit the renderer commits to scrollback.

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh

typeset -gi COLUMNS=80 LINES=10
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY=''
typeset -g SF_PRESENT_STATE=idle SF_PRESENT_FOOTER=''
typeset -g SF_PRESENT_PERMISSION_TOOL='' SF_PRESENT_PERMISSION_TEXT=''
typeset -g SF_PRESENT_PERMISSION_LANGUAGE=''
typeset -gi SF_PRESENT_PERMISSION_PREVIEW_LENGTH=0
typeset -ga SF_PRESENT_QUEUE=() SF_PRESENT_HISTORY=()
typeset -gi SF_PRESENT_HISTORY_NO=0

assert_equal '⠃,⠁,⠁,⠁,⠃,⠆,⡄,⡀,⡀,⡀,⡄,⠆' "${(j:,:)SF_PRESENT_ACTIVITY_FRAMES}"

view() { sf_tui_transcript "$@" || fail 'rendering the transcript failed'; REPLY=$SF_PRESENT_VIEWPORT_TEXT }
# Content settles at the terminal width, so a narrow case sets it up front.
width() { COLUMNS=$(( $1 + 1 )) }
message() {
  sf_tui_action message_start "$1" &&
    sf_tui_action message_delta 0 text "$2" '' &&
    sf_tui_action message_end || fail "cannot present a $1 message"
}
stream() { sf_tui_action message_delta "$1" "$2" "$3" "${4-}" || fail 'cannot stream a delta' }

# The first message opens a full-width numbered role rule.
sf_tui_reset
sf_tui_terminal_reset
message user hello
view 79 20
assert_equal $'─ user ──────────────────────────────────────────────────────────────────── 1 ─\n\nhello' "$REPLY"
assert_equal 79 "${#${REPLY%%$'\n'*}}"

# Repeated roles omit the rule.
message user again
view 79 20
assert_equal $'─ user ──────────────────────────────────────────────────────────────────── 1 ─\n\nhello\n\nagain' "$REPLY"

# Role changes open a new numbered rule.
sf_tui_reset
message user first
message agent reply
view 79 20
[[ $REPLY == *$'\n\n─ agent ─'*$' 2 ─\n\nreply' ]] || fail "agent rule: $REPLY"

# Message spacing collapses blank runs.
sf_tui_reset
message user $'\n\n  spaced  \n\n\n'
view 79 20
[[ $REPLY == *$'\n\n  spaced  ' ]] || fail "trimmed body: $REPLY"

# Blank records claim neither rows nor a section number.
sf_tui_reset
message user $'\n\n'
view 79 20
assert_equal '' "$REPLY"
message user visible
view 79 20
[[ $REPLY == $'─ user '*$' 1 ─\n\nvisible' ]] || fail "blank record consumed a section: $REPLY"

# Settled rows keep the width they were formatted at.
sf_tui_reset
width 12
message user 'alpha beta gamma'
view 12 20
assert_equal $'─ user ─ 1 ─\n\nalpha beta\ngamma' "$REPLY"
view 8 20
assert_equal $'─ user ─ 1 ─\n\nalpha beta\ngamma' "$REPLY"
sf_tui_reset
width 8
message user 'alpha beta gamma'
view 8 20
assert_equal $'─ user ─\n\nalpha\nbeta\ngamma' "$REPLY"

# Viewports keep the last rows.
sf_tui_reset
width 79
message user $'one\ntwo\nthree\nfour'
view 79 3
assert_equal $'two\nthree\nfour' "$REPLY"

# Live messages expose only complete wrapped rows.
sf_tui_reset
sf_tui_action message_start agent
stream 0 text 'hello world'
view 8 20
assert_equal $'─ agent \n\nhello\n⠃' "$REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action message_end
view 8 20
assert_equal $'─ agent \n\nhello\nworld' "$REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"

# A newline makes the current live row safe, and closing keeps the role.
sf_tui_reset
sf_tui_action message_start agent
stream 0 text $'answer\n'
view 20 20
[[ $REPLY == *$'\n\nanswer\n⠃' ]] || fail "newline-closed assistant row: $REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action message_end
message user next
view 20 20
[[ $REPLY == *$'─ agent '*$' 1 ─\n\nanswer\n\n─ user '*$' 2 ─\n\nnext' ]] ||
  fail "settled assistant role retracted: $REPLY"

# An empty response retracts its chrome and releases its section.
sf_tui_reset
sf_tui_action message_start agent
view 12 20
assert_equal $'─ agent  1 ─\n\n⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action message_end
message user next
view 12 20
[[ $REPLY == $'─ user '*$' 1 ─\n\nnext' ]] || fail "empty response retraction: $REPLY"
sf_tui_reset
sf_tui_action message_start agent
stream 0 text $'\n'
stream 1 reasoning $'\n\n'
sf_tui_action message_end
message user visible
view 79 20
[[ $REPLY == $'─ user '*$' 1 ─\n\nvisible' ]] || fail "newline-only retraction: $REPLY"

# Only committed rows leave the queue, and each row commits once.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_action message_start agent
stream 0 text $'one\ntail'
sf_tui_transcript 8 20
sf_tui_terminal_stage
sf_tui_terminal_finish
typeset drained=$PREDISPLAY$'\n'
sf_tui_terminal_restore
stream 0 text $'\ntwo\nlast'
sf_tui_transcript 8 20
sf_tui_terminal_stage
sf_tui_terminal_finish
drained+=$PREDISPLAY$'\n'
sf_tui_terminal_restore
sf_tui_action message_end
sf_tui_transcript 8 20
sf_tui_terminal_stage
sf_tui_terminal_finish
drained+=$PREDISPLAY
assert_equal $'─ agent \n\none\ntail\ntwo\nlast' "$drained"
sf_tui_terminal_restore
sf_tui_transcript 8 20
assert_equal '' "$SF_PRESENT_VIEWPORT_TEXT"

# A width change reflows only uncommitted source.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_action message_start agent
stream 0 text 'alpha beta gamma'
sf_tui_transcript 8 20
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"
sf_tui_terminal_stage
assert_equal 1 "$SF_PRESENT_ROW_HEAD"
sf_tui_transcript 5 20
sf_tui_terminal_finish
assert_equal 1 "$SF_PRESENT_ROW_HEAD"
sf_tui_terminal_restore
SF_PRESENT_STYLE[activity]='fg=#2a2a2a'
sf_tui_transcript 5 20
assert_equal '⠃' "$SF_PRESENT_VIEWPORT_TEXT"
(( ${SF_PRESENT_VIEWPORT_HIGHLIGHTS[(Ie)fg=#2a2a2a]} )) ||
  fail 'the live tail lost its activity style'
unset 'SF_PRESENT_STYLE[activity]'
sf_tui_action message_end
sf_tui_transcript 5 20
assert_equal gamma "$SF_PRESENT_VIEWPORT_TEXT"

# Logical source consumption survives cell-width changes.
SF_PRESENT_STYLE=( message 'fg=1' syntax.strong bold )
sf_tui_reset
sf_tui_terminal_reset
sf_tui_action message_start agent
stream 0 text $'界\t**bold** tail'
sf_tui_transcript 10 20
[[ $SF_PRESENT_SAFE_TEXT == *'界      '* ]] ||
  fail "tab or wide character was not staged: $SF_PRESENT_SAFE_TEXT"
[[ ${(j: :)SF_PRESENT_SAFE_HIGHLIGHTS} == *bold* ]] ||
  fail 'staged Markdown lost its style span'
typeset committed=$SF_PRESENT_SAFE_TEXT
sf_tui_terminal_stage
sf_tui_terminal_finish
sf_tui_terminal_restore
sf_tui_action message_end
sf_tui_transcript 6 20
[[ $SF_PRESENT_VIEWPORT_TEXT != *界* && $SF_PRESENT_VIEWPORT_TEXT != *bold* ]] ||
  fail 'committed wide or styled source reappeared after resize'
[[ $committed == *界* && $committed == *bold* ]] ||
  fail 'the temporary commit lost staged source'
SF_PRESENT_STYLE=()

# Blocks settle in index order; inert blocks only close the one before them.
sf_tui_reset
sf_tui_action message_start agent
stream 0 text first
stream 1 text second
view 79 20
[[ $REPLY == *$'\n\nfirst\n\n⠃' && $REPLY != *second* ]] ||
  fail "adjacent assistant blocks: $REPLY"
stream 2 inert ''
view 79 20
[[ $REPLY == *$'\n\nfirst\n\nsecond' ]] || fail "inert block boundary: $REPLY"
stream 3 reasoning thought 9
view 79 20
[[ $REPLY == *$'✎ Reasoning\n  thought\n  ⠃' ]] || fail "reasoning transition: $REPLY"
stream 4 inert ''
view 79 20
[[ $REPLY == *'Thought for ~9 tokens.' ]] || fail "reasoning settled by an inert block: $REPLY"

# Reasoning previews spend rows and keep the whole-content estimate.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_PREVIEW_REASONING=1
sf_tui_action message_start agent
stream 0 reasoning $'first\nsecond\nthird'
sf_tui_transcript 20 20
[[ $SF_PRESENT_SAFE_TEXT == *'✎ Reasoning'*first* ]] ||
  fail 'reasoning did not stage its safe leading rows'
sf_tui_terminal_stage
sf_tui_terminal_finish
sf_tui_terminal_restore
sf_tui_transcript 10 20
[[ $SF_PRESENT_VIEWPORT_TEXT != *Reasoning* && $SF_PRESENT_VIEWPORT_TEXT != *second* ]] ||
  fail 'resize restored consumed chrome or drained hidden rows'
[[ $SF_PRESENT_VIEWPORT_TEXT == *'~5'* ]] ||
  fail 'partial reasoning lost its whole-content estimate'
sf_tui_action message_end
sf_tui_transcript 10 20
[[ $SF_PRESENT_VIEWPORT_TEXT == *'~5'* ]] ||
  fail 'settled reasoning lost its estimate'
sf_tui_terminal_stage
sf_tui_terminal_finish
[[ $PREDISPLAY != *second* ]] || fail 'a clamp committed the rows it hid'
sf_tui_terminal_reset

# Live reasoning tails remain unsafe, and usage refines the estimate.
sf_tui_reset
sf_tui_action message_start agent
stream 0 reasoning $'first\nsecond'
view 79 20
[[ $REPLY == $'─ agent '*$' 1 ─\n\n✎ Reasoning\n  first\n  … ~3 tokens ⠃' ]] ||
  fail "live reasoning preview: $REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action usage '3 ↑ 1 ↓' 4
sf_tui_action message_end
view 79 20
[[ $REPLY == $'─ agent '*$' 1 ─\n\n✎ Reasoning\n  first\n  … Thought for ~4 tokens.' ]] ||
  fail "settled reasoning preview: $REPLY"
assert_equal 5 "$SF_PRESENT_SAFE_ROWS"

# Collapsed reasoning settles as one summary.
sf_tui_reset
SF_PRESENT_PREVIEW_REASONING=0
sf_tui_action message_start agent
stream 0 reasoning thought
view 79 20
[[ $REPLY == *$'✎ Thinking… ⠃' ]] || fail "live collapsed reasoning: $REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action message_end
view 79 20
[[ $REPLY == *$'✎ Thought for ~2 tokens.' ]] || fail "settled collapsed reasoning: $REPLY"
SF_PRESENT_PREVIEW_REASONING=full

# System text is clamped to the configured context budget.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=0
message system $'one\ntwo'
view 79 20
[[ $REPLY == $'─ system '*$'\n\n… ~2 tokens' ]] || fail "collapsed system: $REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"
sf_tui_reset
width 8
message system $'one\ntwo'
view 8 20
for row in "${(@f)REPLY}"; do
  (( ${#row} <= 8 )) || fail "narrow system row overflowed: $row"
done
sf_tui_reset
width 79
SF_PRESENT_PREVIEW_CONTEXT=1
message system $'first row\nsecond row\nthird row'
view 79 20
[[ $REPLY == $'─ system '*$'\n\nfirst row\n… ~8 tokens' ]] || fail "previewed system: $REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"
SF_PRESENT_PREVIEW_CONTEXT=full

# Incomplete inline syntax withholds only a bounded suffix.
sf_tui_reset
sf_tui_action message_start agent
stream 0 text '**open word word tail'
view 10 20
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_reset
sf_tui_action message_start agent
stream 0 text \
  '**open word word word word word word word word word word word word word word word word word word word word tail'
view 10 40
(( SF_PRESENT_SAFE_ROWS > 0 )) || fail 'a tall inline stream did not drain'
sf_tui_reset
sf_tui_action message_start agent
stream 0 text $'```js\nconst x = 1;\ntail'
view 20 20
(( SF_PRESENT_SAFE_ROWS > 0 )) || fail 'an open fence withheld stable rows'

# Markdown styling is independent of chunk boundaries.
SF_PRESENT_STYLE=( message m syntax.heading h syntax.strong s )
sf_tui_reset
sf_tui_action message_start agent
stream 0 text '# A **bold '
view 12 40
stream 0 text 'heading that wraps** '
view 12 40
stream 0 text 'and keeps growing'
view 12 40
typeset chunked_text=$SF_PRESENT_VIEWPORT_TEXT
typeset chunked_spans="${(j:|:)SF_PRESENT_VIEWPORT_HIGHLIGHTS}"
sf_tui_reset
sf_tui_action message_start agent
stream 0 text '# A **bold heading that wraps** and keeps growing'
view 12 40
assert_equal "$chunked_text" "$SF_PRESENT_VIEWPORT_TEXT"
assert_equal "$chunked_spans" "${(j:|:)SF_PRESENT_VIEWPORT_HIGHLIGHTS}"
SF_PRESENT_STYLE=()

print -r -- ok
