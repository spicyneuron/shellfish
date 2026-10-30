#!/usr/bin/env zsh

# Message and reasoning presentation. Actions arrive from the projector; rows
# are the atomic unit the renderer commits to scrollback.

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh

typeset -gi COLUMNS=80 LINES=10
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY=''
typeset -g SF_PRESENT_STATE=idle SF_PRESENT_FOOTER=''
typeset -g SF_PRESENT_PERMISSION_TOOL='' SF_PRESENT_PERMISSION_TEXT=''
typeset -ga SF_PRESENT_QUEUE=() SF_PRESENT_HISTORY=()
typeset -gi SF_PRESENT_HISTORY_NO=0

assert_equal '⠃,⠁,⠁,⠁,⠃,⠆,⡄,⡀,⡀,⡀,⡄,⠆' "${(j:,:)SF_PRESENT_ACTIVITY_FRAMES}"

view() {
  sf_tui_transcript "$@" || fail 'rendering the transcript failed'
  REPLY=${SF_PRESENT_VIEWPORT_TEXT%$'\n'}
}
# Content commits at the terminal width, so a narrow case sets it up front.
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
sf_tui_repaint || fail 'rendering the prompt failed'
[[ $PREDISPLAY == *$'hello\n\n─'* ]] || fail "prompt boundary: $PREDISPLAY"

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
assert_equal $'three\nfour' "$REPLY"

# Live text commits whole lines; the line still arriving stays hidden.
sf_tui_reset
sf_tui_terminal_reset
width 8
sf_tui_action message_start agent
stream 0 text 'hello world'
view 8 20
assert_equal $'─ agent \n\n⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
stream 0 text $' again\nnext'
view 8 20
assert_equal $'─ agent \n\nhello\nworld\nagain\n⠃' "$REPLY"
assert_equal 5 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action message_end
view 8 20
assert_equal $'─ agent \n\nhello\nworld\nagain\nnext' "$REPLY"

# Blank lines wait for the text after them, so a commit never ends on one.
sf_tui_reset
sf_tui_terminal_reset
width 20
sf_tui_action message_start agent
stream 0 text $'one\n\n'
view 20 20
assert_equal one "${SF_PRESENT_SAFE_TEXT##*$'\n'}"
stream 0 text $'two\n'
view 20 20
[[ $REPLY == *$'\n\none\n\ntwo\n⠃' ]] || fail "blank line between commits: $REPLY"
sf_tui_action message_end

# A newline-closed line settles with its role.
sf_tui_reset
sf_tui_action message_start agent
stream 0 text $'answer\n'
sf_tui_action message_end
message user next
view 20 20
[[ $REPLY == *$'─ agent '*$' 1 ─\n\nanswer\n\n─ user '*$' 2 ─\n\nnext' ]] ||
  fail "settled assistant role retracted: $REPLY"

# An empty response retracts its chrome and releases its section.
sf_tui_reset
width 12
sf_tui_action message_start agent
view 12 20
assert_equal $'─ agent  1 ─\n\n⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action message_end
message user next
view 12 20
[[ $REPLY == $'─ user '*$' 1 ─\n\nnext' ]] || fail "empty response retraction: $REPLY"
sf_tui_reset
width 79
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
width 8
sf_tui_action message_start agent
stream 0 text $'one\ntail\n'
sf_tui_transcript 8 20
sf_tui_terminal_stage
sf_tui_terminal_finish
typeset drained=$PREDISPLAY$'\n'
sf_tui_terminal_restore
stream 0 text $'two\nlast'
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

# A blank line between fences commits at the start of the next one.
sf_tui_reset
sf_tui_terminal_reset
width 20
sf_tui_action message_start agent
stream 0 text $'```json\n{}\n```\n'
sf_tui_transcript 20 20
sf_tui_terminal_stage
sf_tui_terminal_finish
sf_tui_terminal_restore
stream 0 text $'\n'
sf_tui_transcript 20 20
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
stream 0 text $'```jsonc\n'
sf_tui_transcript 20 20
assert_equal $'\n```jsonc' "$SF_PRESENT_SAFE_TEXT"

# Committed rows keep their width; the rest formats at the width drawn last.
sf_tui_reset
sf_tui_terminal_reset
width 8
sf_tui_action message_start agent
stream 0 text $'alpha beta\ngamma delta'
sf_tui_transcript 8 20
sf_tui_terminal_stage
sf_tui_terminal_finish
sf_tui_terminal_restore
SF_PRESENT_STYLE[activity]='fg=#2a2a2a'
sf_tui_transcript 5 20
assert_equal '⠃' "$SF_PRESENT_VIEWPORT_TEXT"
(( ${SF_PRESENT_VIEWPORT_HIGHLIGHTS[(Ie)fg=#2a2a2a]} )) ||
  fail 'the status row lost its activity style'
unset 'SF_PRESENT_STYLE[activity]'
sf_tui_action message_end
view 5 20
assert_equal $'gamma\ndelta' "$REPLY"

# Tabs, wide characters, and Markdown styles commit intact.
SF_PRESENT_STYLE=( message 'fg=1' syntax.strong bold )
sf_tui_reset
sf_tui_terminal_reset
sf_tui_action message_start agent
stream 0 text $'界\t**bold** tail\n'
sf_tui_transcript 10 20
[[ $SF_PRESENT_SAFE_TEXT == *'界      '* ]] ||
  fail "tab or wide character was not staged: $SF_PRESENT_SAFE_TEXT"
[[ ${(j: :)SF_PRESENT_SAFE_HIGHLIGHTS} == *bold* ]] ||
  fail 'staged Markdown lost its style span'
SF_PRESENT_STYLE=()

# Blocks settle in index order; inert blocks only close the one before them.
sf_tui_reset
width 79
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
[[ $REPLY == *$'  ⠃' ]] || fail "reasoning transition: $REPLY"
stream 4 inert ''
view 79 20
[[ $REPLY == *$'✎ thought' ]] ||
  fail "reasoning settled by an inert block: $REPLY"

# Reasoning previews spend rows and keep the whole-content estimate.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_PREVIEW_REASONING=1
sf_tui_action message_start agent
stream 0 reasoning $'first\nsecond\nthird'
sf_tui_transcript 20 20
[[ $SF_PRESENT_SAFE_TEXT == *'✎ first'* ]] ||
  fail 'reasoning preview lost its leading rows'
sf_tui_terminal_stage
sf_tui_terminal_finish
sf_tui_terminal_restore
sf_tui_transcript 10 20
[[ $SF_PRESENT_VIEWPORT_TEXT != *second* ]] ||
  fail 'resize restored committed chrome or showed hidden rows'
[[ $SF_PRESENT_VIEWPORT_TEXT != *'~5'* ]] ||
  fail 'live reasoning showed its estimate before settling'
sf_tui_action message_end
sf_tui_transcript 10 20
[[ $SF_PRESENT_VIEWPORT_TEXT == *'~5'* ]] ||
  fail 'settled reasoning lost its estimate'
sf_tui_terminal_stage
sf_tui_terminal_finish
[[ $PREDISPLAY != *second* ]] || fail 'a clamp committed the rows it hid'
sf_tui_terminal_reset

# A spent preview shows only activity until it settles; usage refines the
# settled estimate.
sf_tui_reset
sf_tui_action message_start agent
stream 0 reasoning $'first\nsecond'
view 79 20
[[ $REPLY == $'─ agent '*$' 1 ─\n\n✎ first\n  ⠃' ]] ||
  fail "live reasoning preview: $REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action usage '3 ↑ 1 ↓' 4
sf_tui_action message_end
view 79 20
[[ $REPLY == $'─ agent '*$' 1 ─\n\n✎ first\n  … ~4 tokens' ]] ||
  fail "settled reasoning preview: $REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"

# Wrapped reasoning keeps the icon on its first line only.
sf_tui_reset
SF_PRESENT_PREVIEW_REASONING=full
width 13
sf_tui_action message_start agent
stream 0 reasoning $'a reasoning block long enough to wrap\nand a second line'
sf_tui_action message_end
view 14 20
typeset icon_tail=${REPLY#*✎}
[[ $REPLY == *'✎ a'* && $icon_tail != *✎* ]] ||
  fail "wrapped reasoning repeated its icon: $REPLY"
width 79

# Collapsed reasoning settles as one summary.
sf_tui_reset
SF_PRESENT_PREVIEW_REASONING=0
sf_tui_action message_start agent
stream 0 reasoning $'thought\nmore'
view 79 20
[[ $REPLY == *$'✎ Thinking… ⠃' && $REPLY != *thought* ]] ||
  fail "live collapsed reasoning: $REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action message_end
view 79 20
[[ $REPLY == *$'─\n\n✎ Thought for ~3 tokens.' ]] || fail "settled collapsed reasoning: $REPLY"
SF_PRESENT_PREVIEW_REASONING=full

# System text is clamped to the configured context budget.
sf_tui_reset
SF_PRESENT_PREVIEW=0
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
SF_PRESENT_PREVIEW=1
message system $'first row\nsecond row\nthird row'
view 79 20
[[ $REPLY == $'─ system '*$'\n\nfirst row\n… ~8 tokens' ]] || fail "previewed system: $REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"
SF_PRESENT_PREVIEW=full

# Lines inside an open fence commit as they complete.
sf_tui_reset
sf_tui_action message_start agent
stream 0 text $'```js\nconst x = 1;\ntail'
view 20 20
[[ $SF_PRESENT_SAFE_TEXT == *$'```js\nconst x = 1;' ]] ||
  fail "an open fence withheld complete lines: $SF_PRESENT_SAFE_TEXT"

# Streamed and replayed text produce the same rows and styles.
SF_PRESENT_STYLE=( message m syntax.heading h syntax.strong s syntax.code c
  syntax.fence f syntax.keyword k syntax.comment o )
typeset source=$'# A **bold heading** that wraps\n\n```js\nconst x = 1; /* open\nstill */ let y\n```\n\n- item `code`\n'
integer cut
sf_tui_reset
width 12
sf_tui_action message_start agent
for (( cut = 1; cut <= ${#source}; cut += 7 )); do
  stream 0 text "${source[cut,cut + 6]}"
  view 12 40
done
sf_tui_action message_end
view 12 40
typeset chunked_text=$SF_PRESENT_VIEWPORT_TEXT
typeset chunked_spans="${(j:|:)SF_PRESENT_VIEWPORT_HIGHLIGHTS}"
sf_tui_reset
message agent "$source"
view 12 40
assert_equal "$chunked_text" "$SF_PRESENT_VIEWPORT_TEXT"
assert_equal "$chunked_spans" "${(j:|:)SF_PRESENT_VIEWPORT_HIGHLIGHTS}"
[[ $chunked_spans == *'|k'* && $chunked_spans == *'|o'* ]] ||
  fail "streamed code lost its fence state: $chunked_spans"
SF_PRESENT_STYLE=()

print -r -- ok
