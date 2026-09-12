#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh \
  libexec/tui/render/messages.zsh libexec/tui/render/hooks.zsh \
  libexec/tui/render/terminal.zsh \
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
sf_tui_reset
sf_tui_event user hi
view 10 20
assert_equal $'─ user ───\n\nhi' "$REPLY"
sf_tui_reset
sf_tui_event user hi
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

# Formatting uses the current width, then settled rows keep that width.
sf_tui_reset
sf_tui_event user 'alpha beta gamma'
view 12 20
assert_equal $'─ user ─ 1 ─\n\nalpha beta\ngamma' "$REPLY"
view 8 20
assert_equal $'─ user ─ 1 ─\n\nalpha beta\ngamma' "$REPLY"
sf_tui_reset
sf_tui_event user 'alpha beta gamma'
view 8 20
assert_equal $'─ user ─\n\nalpha\nbeta\ngamma' "$REPLY"

# The viewport keeps the last rows the budget allows.
sf_tui_reset
sf_tui_event user $'one\ntwo\nthree\nfour'
view 79 3
assert_equal $'two\nthree\nfour' "$REPLY"

# A complete record is wholly safe, while each commit stays within its budget.
sf_tui_reset
sf_tui_event user hello
sf_tui_transcript 79 20
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"
sf_tui_transcript 79 2
assert_equal 2 "$SF_PRESENT_SAFE_ROWS"
assert_equal $'\nhello' "$SF_PRESENT_VIEWPORT_TEXT"

# A staging pass stops at the end of the safe run rather than formatting the
# transcript behind it, so it stages exactly what a full pass would and leaves
# the viewport to the repaint that follows the commit.
sf_tui_reset
sf_tui_event user $'one\ntwo\nthree'
sf_tui_event user $'four\nfive\nsix'
sf_tui_transcript 79 4
typeset staged_text=$SF_PRESENT_SAFE_TEXT staged_rows=$SF_PRESENT_SAFE_ROWS
(( staged_rows )) || fail 'the full pass staged nothing to compare'
[[ -n $SF_PRESENT_VIEWPORT_TEXT ]] || fail 'the full pass drew no viewport to skip'
sf_tui_transcript 79 4 stage
assert_equal "$staged_text" "$SF_PRESENT_SAFE_TEXT"
assert_equal "$staged_rows" "$SF_PRESENT_SAFE_ROWS"
assert_equal '' "$SF_PRESENT_VIEWPORT_TEXT"

# With nothing to commit there is no repaint behind the staging pass, so it
# builds the viewport itself. A budget under the leading rule stages nothing.
sf_tui_transcript 79 1
typeset drawn=$SF_PRESENT_VIEWPORT_TEXT
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
[[ -n $drawn ]] || fail 'the full pass drew no viewport to compare'
sf_tui_transcript 79 1 stage
assert_equal "$drawn" "$SF_PRESENT_VIEWPORT_TEXT"

# A closed record crosses the formatter boundary once. Draining its settled
# rows in small blocks never returns to the formatter.
sf_tui_reset
typeset -gi format_calls=0
typeset saved_format_message=$functions[sf_tui_format_message] tall_message=''
integer line
sf_tui_format_message() {
  (( ++format_calls ))
  sf_tui_format_message_saved "$@"
}
functions[sf_tui_format_message_saved]=$saved_format_message
for (( line = 1; line <= 40; line++ )); do
  tall_message+="line $line"$'\n'
done
sf_tui_event user "$tall_message"
while true; do
  sf_tui_transcript 12 5 stage || fail 'draining settled rows failed'
  (( SF_PRESENT_SAFE_ROWS )) || break
  sf_tui_rows_consume $SF_PRESENT_SAFE_ROWS || fail 'consuming settled rows failed'
done
assert_equal 1 "$format_calls"
assert_equal 0 "${#SF_PRESENT_KIND}"
functions[sf_tui_format_message]=$saved_format_message
unfunction sf_tui_format_message_saved

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

# Formatting advances settled source once. Staging leaves the settled-row cursor
# unchanged, and a resize affects only the live tail.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 'alpha beta gamma'
sf_tui_transcript 8 20
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"
assert_equal gamma "$SF_PRESENT_TEXT[1]"
sf_tui_terminal_stage
assert_equal 1 "$SF_PRESENT_ROW_HEAD"
sf_tui_transcript 5 20
assert_equal gamma "$SF_PRESENT_TEXT[1]"
sf_tui_terminal_finish
assert_equal 1 "$SF_PRESENT_ROW_HEAD"
assert_equal gamma "$SF_PRESENT_TEXT[1]"
sf_tui_terminal_restore
sf_tui_transcript 5 20
assert_equal '⠃' "$SF_PRESENT_VIEWPORT_TEXT"
sf_tui_event assistant_end
sf_tui_transcript 5 20
assert_equal gamma "$SF_PRESENT_VIEWPORT_TEXT"

# Successive stream commits consume each row once, including chrome on only
# the first commit and the partial tail only after assistant settlement.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 $'one\ntail'
sf_tui_transcript 8 20
sf_tui_terminal_stage
sf_tui_terminal_finish
typeset drained=$PREDISPLAY
drained+=$'\n'
sf_tui_terminal_restore
sf_tui_event assistant_message_delta 0 $'\ntwo\nlast'
sf_tui_transcript 8 20
sf_tui_terminal_stage
sf_tui_terminal_finish
drained+=$PREDISPLAY
drained+=$'\n'
sf_tui_terminal_restore
sf_tui_event assistant_end
sf_tui_transcript 8 20
sf_tui_terminal_stage
sf_tui_terminal_finish
drained+=$PREDISPLAY
assert_equal $'─ agent \n\none\ntail\ntwo\nlast' "$drained"
assert_equal 0 "${#SF_PRESENT_KIND}"

# Consumption counts logical source while wrapping counts cells, so a tab's
# projected spaces and a wide character commit once and never reappear.
SF_PRESENT_STYLE=( message 'fg=1' syntax.strong bold )
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 $'界\t**bold** tail'
sf_tui_transcript 10 20
[[ $SF_PRESENT_SAFE_TEXT == *'界      '* ]] ||
  fail "tab or wide character was not staged: $SF_PRESENT_SAFE_TEXT"
[[ ${(j: :)SF_PRESENT_SAFE_HIGHLIGHTS} == *bold* ]] ||
  fail 'staged Markdown lost its style span'
typeset committed=$SF_PRESENT_SAFE_TEXT
sf_tui_terminal_stage
sf_tui_terminal_finish
sf_tui_terminal_restore
sf_tui_event assistant_end
sf_tui_transcript 6 20
[[ $SF_PRESENT_VIEWPORT_TEXT != *界* && $SF_PRESENT_VIEWPORT_TEXT != *bold* ]] ||
  fail 'committed wide or styled source reappeared after resize'
[[ $committed == *界* && $committed == *bold* ]] ||
  fail 'the temporary commit lost staged source'
SF_PRESENT_STYLE=()

# Reasoning consumes its heading once and keeps the whole-block estimate for the
# summary. Committed rows spend the preview budget, so the clamp stays instead of
# draining a window at a time.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_PREVIEW_REASONING=1
sf_tui_event assistant_start
sf_tui_event assistant_reasoning_delta 0 $'first\nsecond\nthird'
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
sf_tui_event assistant_end
sf_tui_transcript 10 20
[[ $SF_PRESENT_VIEWPORT_TEXT == *'~5'* ]] ||
  fail 'settled reasoning lost retained formatter metadata'
sf_tui_terminal_stage
sf_tui_terminal_finish
[[ $PREDISPLAY != *second* ]] || fail 'a clamp committed the rows it hid'
assert_equal 0 "${#SF_PRESENT_KIND}"
SF_PRESENT_PREVIEW_REASONING=full
sf_tui_terminal_reset

# System context owns its preview and whole-content estimate. A zero preview is
# only the clamp; a positive preview counts wrapped body rows, not its chrome.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=0
sf_tui_event system $'one\ntwo'
view 79 20
[[ $REPLY == $'─ system '*$'\n\n… ~2 tokens' ]] || fail "collapsed system: $REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"
sf_tui_reset
sf_tui_event system $'one\ntwo'
view 8 20
for row in "${(@f)REPLY}"; do
  (( ${#row} <= 8 )) || fail "narrow system row overflowed: $row"
done

sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=1
sf_tui_event system $'first row\nsecond row\nthird row'
view 79 20
[[ $REPLY == $'─ system '*$'\n\nfirst row\n… ~8 tokens' ]] || fail "previewed system: $REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"

# Assistant start owns agent chrome and activity, but none of it is safe until
# stable content exists. Ending an empty stream retracts both chrome and number.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=full
sf_tui_event assistant_start
view 12 20
assert_equal $'─ agent  1 ─\n\n⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event assistant_end
sf_tui_event user next
view 12 20
[[ $REPLY == $'─ user '*$' 1 ─\n\nnext' ]] || fail "empty assistant retraction: $REPLY"

# Live assistant text shows only complete wrapped rows. The mutable tail is
# represented by activity until settlement, when it appears exactly once.
sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 'hello world'
view 8 20
assert_equal $'─ agent \n\nhello\n⠃' "$REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event assistant_end
view 8 20
assert_equal $'─ agent \n\nhello\nworld' "$REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"

# A newline closes the partial line immediately, so the body row joins the safe
# prefix even though the formatter remains live for more content.
sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 $'answer\n'
view 20 20
[[ $REPLY == *$'\n\nanswer\n⠃' ]] || fail "newline-closed assistant row: $REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event assistant_end
sf_tui_event user next
view 20 20
[[ $REPLY == *$'─ agent '*$' 1 ─\n\nanswer\n\n─ user '*$' 2 ─\n\nnext' ]] ||
  fail "settled assistant role retracted: $REPLY"

# Adjacent blocks of the same visible kind remain separate, and visible or
# opaque kind transitions settle the preceding source block in order.
sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 first
sf_tui_event assistant_message_delta 1 second
view 79 20
[[ $REPLY == *$'\n\nfirst\n\n⠃' && $REPLY != *second* ]] ||
  fail "adjacent assistant blocks: $REPLY"
sf_tui_event assistant_reasoning_opaque 2
view 79 20
[[ $REPLY == *$'\n\nfirst\n\nsecond' ]] || fail "opaque reasoning boundary: $REPLY"
sf_tui_event assistant_reasoning_delta 3 thought 9
view 79 20
[[ $REPLY == *$'✎ Reasoning\n  thought\n  ⠃' ]] || fail "reasoning transition: $REPLY"
sf_tui_event assistant_tool_call_delta 4
view 79 20
[[ $REPLY == *'Thought for ~9 tokens.' ]] || fail "tool-call boundary: $REPLY"

# Expanded reasoning displays its partial tail but keeps it unsafe. A preview
# clamp owns activity while live and uses the exact whole-block total at end.
sf_tui_reset
SF_PRESENT_PREVIEW_REASONING=1
sf_tui_event assistant_start
sf_tui_event assistant_reasoning_delta 0 $'first\nsecond'
view 79 20
[[ $REPLY == $'─ agent '*$' 1 ─\n\n✎ Reasoning\n  first\n  … ~3 tokens ⠃' ]] ||
  fail "live reasoning preview: $REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event reasoning_tokens 4
sf_tui_event assistant_end
view 79 20
[[ $REPLY == $'─ agent '*$' 1 ─\n\n✎ Reasoning\n  first\n  … Thought for ~4 tokens.' ]] ||
  fail "settled reasoning preview: $REPLY"
assert_equal 5 "$SF_PRESENT_SAFE_ROWS"

# A collapsed reasoning block remains wholly unsafe while live, then settles
# as one summary. Newline-only streamed blocks retract on transition.
sf_tui_reset
SF_PRESENT_PREVIEW_REASONING=0
sf_tui_event assistant_start
sf_tui_event assistant_reasoning_delta 0 thought
view 79 20
[[ $REPLY == *$'✎ Thinking… ⠃' ]] || fail "live collapsed reasoning: $REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event assistant_end
view 79 20
[[ $REPLY == *$'✎ Thought for ~2 tokens.' ]] || fail "settled collapsed reasoning: $REPLY"

sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 $'\n'
sf_tui_event assistant_reasoning_delta 1 $'\n\n'
sf_tui_event assistant_end
sf_tui_event user visible
view 79 20
[[ $REPLY == $'─ user '*$' 1 ─\n\nvisible' ]] || fail "newline-only retraction: $REPLY"

# An incomplete inline construct holds only a bounded suffix of stable rows;
# a tall stream still drains. Open fences do not withhold otherwise safe rows.
sf_tui_reset
SF_PRESENT_PREVIEW_REASONING=full
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 '**open word word tail'
view 10 20
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 \
  '**open word word word word word word word word word word word word word word word word word word word word tail'
view 10 40
(( SF_PRESENT_SAFE_ROWS > 0 )) || fail 'a tall inline stream did not drain'
sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 $'```js\nconst x = 1;\ntail'
view 20 20
(( SF_PRESENT_SAFE_ROWS > 0 )) || fail 'an open fence withheld stable rows'

# Chunk boundaries do not change nested Markdown styling.
SF_PRESENT_STYLE=( message m syntax.heading h syntax.strong s )
sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 '# A **bold '
view 12 40
sf_tui_event assistant_message_delta 0 'heading that wraps** '
view 12 40
sf_tui_event assistant_message_delta 0 'and keeps growing'
view 12 40
typeset chunked_text=$SF_PRESENT_VIEWPORT_TEXT
typeset chunked_spans="${(j:|:)SF_PRESENT_VIEWPORT_HIGHLIGHTS}"
sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 '# A **bold heading that wraps** and keeps growing'
view 12 40
assert_equal "$chunked_text" "$SF_PRESENT_VIEWPORT_TEXT"
assert_equal "$chunked_spans" "${(j:|:)SF_PRESENT_VIEWPORT_HIGHLIGHTS}"
SF_PRESENT_STYLE=()

# Scan continuation is formatter-local: growing a long line does work
# proportional to new content rather than rescanning its retained prefix.
sf_tui_reset
typeset -gi scanned=0
functions[sf_tui_markdown_saved]=$functions[sf_tui_markdown_highlight]
sf_tui_markdown_highlight() {
  scanned=$(( scanned + ${#1} ))
  sf_tui_markdown_saved "$@"
}
sf_tui_event assistant_start
for (( span = 1; span <= 24; span++ )); do
  sf_tui_event assistant_message_delta 0 'lorem ipsum '
  view 20 20
done
(( scanned <= 24 * 12 * 3 )) || fail "rescanned growing Markdown: $scanned"
functions[sf_tui_markdown_highlight]=$functions[sf_tui_markdown_saved]
unfunction sf_tui_markdown_saved

# Reasoning clamps retain the formatter's base style and apply the clamp style
# afterward.
SF_PRESENT_STYLE=( message 'fg=1' reasoning 'fg=2' clamp 'fg=3' )
SF_PRESENT_PREVIEW_REASONING=1
sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_reasoning_delta 0 $'first\nsecond'
sf_tui_transcript 20 20 || fail 'styled reasoning clamp did not render'
[[ ${(j:|:)SF_PRESENT_VIEWPORT_HIGHLIGHTS} == *'fg=2'*'fg=3'* ]] ||
  fail 'reasoning clamp styles were not layered'
SF_PRESENT_STYLE=()
