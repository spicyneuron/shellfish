#!/usr/bin/env zsh

# Executions cover tool calls and hook output. One mutable block shows the
# running work and its result replaces it in place.

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/main.zsh

typeset -gi COLUMNS=80 LINES=10
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY=''

view() {
  sf_tui_transcript "${1:-80}" 100 || fail 'rendering executions failed'
  REPLY=$SF_PRESENT_VIEWPORT_TEXT
}
assert_tail() { [[ $REPLY == *"$1" ]] || fail "expected tail: $1" "actual: $REPLY" }
has_style() { (( ${SF_PRESENT_VIEWPORT_HIGHLIGHTS[(Ie)$1]} )) }
message() {
  sf_tui_action message_start "$1" &&
    sf_tui_action message_delta 0 text "$2" '' &&
    sf_tui_action message_end || fail "cannot present a $1 message"
}

# Standalone activity is an unsafe tail.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_activity_start
view
assert_equal '⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action message_start agent
sf_tui_action message_end
sf_tui_activity_stop
view
assert_equal '' "$REPLY"

# Visible blocks replace activity; inert blocks resume it.
sf_tui_activity_start
sf_tui_action message_start agent
sf_tui_action message_delta 0 text before ''
sf_tui_action message_delta 1 inert '' ''
view
assert_tail $'before\n\n⠃'
sf_tui_action message_delta 2 text after ''
sf_tui_action message_end
view
assert_tail $'before\n\nafter'
sf_tui_activity_stop

# A call is one live entry whose text is replaced by its result.
sf_tui_reset
sf_tui_activity_start
sf_tui_action message_start agent
sf_tui_action message_delta 0 inert '' ''
sf_tui_action message_end
sf_tui_action execution_update call_1 shell tool 'shell · make test'
view
assert_tail $'⛭ shell · make test\n╰ ⠃'
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_action execution_end call_1 shell tool $'shell · failed\ndetail\nexit 1'
view
assert_tail $'⛭ shell · failed\n│ detail\n╰ exit 1\n\n⠃'
assert_equal 5 "$SF_PRESENT_SAFE_ROWS"
sf_tui_activity_stop

# Hook activity borrows the live tool block until the tool settles it.
sf_tui_reset
sf_tui_activity_start
sf_tui_action execution_update hooked shell tool $'shell\nmake test'
sf_tui_action execution_update h1 guard notice $'guard\nchecking'
view
assert_tail $'⛭ guard\n│ checking\n╰ ⠃'
sf_tui_action execution_update h1 guard notice $'guard\napproved'
view
assert_tail $'⛭ guard\n│ approved\n╰ ⠃'
sf_tui_action execution_end hooked shell tool $'shell\nmake test\ndone'
view
assert_tail $'⛭ shell\n│ make test\n╰ done\n\n⠃'
sf_tui_activity_stop

# A settled result with no running block stands on its own.
sf_tui_reset
sf_tui_action execution_end queued shell tool 'shell · cancelled'
view
assert_tail $'⛭ shell · cancelled\n╰'

# A held turn hides only the spinner.
sf_tui_reset
sf_tui_activity_start
sf_tui_action execution_update permission shell tool $'shell · pwd\nwaiting'
sf_tui_activity_hold
view
assert_tail $'⛭ shell · pwd\n│ waiting'
sf_tui_activity_start
view
assert_tail $'⛭ shell · pwd\n│ waiting\n╰ ⠃'
sf_tui_action execution_end permission shell tool 'shell · sandbox bypass denied'
view
assert_tail $'⛭ shell · sandbox bypass denied\n╰\n\n⠃'
sf_tui_activity_stop

# Hook notices carry their own glyph and style.
sf_tui_reset
sf_tui_activity_start
SF_PRESENT_STYLE[execution]='fg=#111111'
SF_PRESENT_STYLE[activity]='fg=#222222'
sf_tui_action execution_update h1 project notice $'project · Inspecting\nfiles'
view
assert_equal $'ℹ project · Inspecting\n│ files\n╰ ⠃' "$REPLY"
has_style 'fg=#111111' || fail 'hook notice did not retain its own style'
has_style 'fg=#222222' || fail 'hook activity did not use the agent style'
sf_tui_action execution_end h1 project notice $'project · Ready\nresult'
view
assert_equal $'ℹ project · Ready\n╰ result\n\n⠃' "$REPLY"
assert_equal 2 "$SF_PRESENT_SAFE_ROWS"
unset 'SF_PRESENT_STYLE[execution]' 'SF_PRESENT_STYLE[activity]'
sf_tui_activity_stop

# A running view with no result of its own is retained, not retracted.
sf_tui_reset
sf_tui_action execution_update h1 silent notice 'silent · Working'
message user ready
view
[[ $REPLY == $'ℹ silent · Working\n╰\n\n─ user '*$' 1 ─\n\nready' ]] ||
  fail "following message did not retain the hook view: $REPLY"

# Loaded results append already settled.
sf_tui_reset
sf_tui_action execution_end h1 prompt notice $'prompt\nfirst\nsecond'
view
assert_equal $'ℹ prompt\n│ first\n╰ second' "$REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"

# Context output is clamped to the configured budget.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=1
sf_tui_action execution_end h1 probe context $'probe\nfirst\nsecond\nthird'
view
assert_equal $'↪ probe\n│ first\n╰ … ~6 tokens' "$REPLY"
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=0
sf_tui_action execution_end h1 prompt context $'prompt\nfirst\nsecond'
view
assert_equal $'↪ prompt\n╰ … ~5 tokens' "$REPLY"
SF_PRESENT_PREVIEW_CONTEXT=full

# Execution text is plain even when it resembles a diff.
sf_tui_reset
SF_PRESENT_STYLE=( tool tool divider rail
  'syntax.added' 'fg=green,bg=darkgreen'
  'syntax.removed' 'fg=red,bg=darkred' )
sf_tui_action execution_update diff edit_file tool 'edit_file · path'
sf_tui_action execution_end diff edit_file tool $'edit_file · path\n-old\n+new'
view 20
assert_tail $'⛭ edit_file · path\n│ -old\n╰ +new'
! has_style 'fg=red,bg=darkred' || fail 'execution text received diff highlighting'
! has_style 'fg=green,bg=darkgreen' || fail 'execution text received diff highlighting'
SF_PRESENT_STYLE=()

# Errors settle a pending execution and close the turn.
sf_tui_reset
sf_tui_action execution_update abandoned shell tool 'shell · run'
sf_tui_action error Failed broken
view
assert_tail $'⛭ shell · run\n╰\n\n✕ Failed\n  broken'
sf_tui_reset
sf_tui_action message_start agent
sf_tui_action message_delta 0 text partial ''
sf_tui_action error Failed $'detail one\ndetail two'
view
assert_tail $'partial\n\n✕ Failed\n  detail one\n  detail two'
assert_equal 7 "$SF_PRESENT_SAFE_ROWS"
message user retry
view
[[ $REPLY == *$'─ user '*$' 2 ─\n\nretry' ]] || fail "post-error section: $REPLY"

# Settled rows taller than the terminal budget drain in source order.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_action execution_update tall shell tool 'shell · one'
sf_tui_action execution_end tall shell tool $'shell · one\ntwo\nthree\nfour\nfive'
typeset drained=''
integer batch
for batch in 1 2 3; do
  sf_tui_transcript 20 4 || fail 'rendering a tall execution failed'
  (( ! SF_PRESENT_SAFE_ROWS )) || {
    sf_tui_terminal_stage || fail 'staging a tall execution failed'
    sf_tui_terminal_finish || fail 'committing a tall execution failed'
    drained+=$PREDISPLAY$'\n'
    sf_tui_terminal_restore
  }
done
assert_equal $'─ agent ──────── 1 ─\n\n⛭ shell · one\n│ two\n│ three\n│ four\n╰ five' \
  "${drained%$'\n'}"

print -r -- ok
