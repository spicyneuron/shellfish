#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh \
  libexec/tui/render/messages.zsh libexec/tui/render/hooks.zsh \
  libexec/tui/render/terminal.zsh \
  libexec/tui/render/view.zsh

typeset -gi COLUMNS=80 LINES=10
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY=''

view() {
  sf_tui_transcript "$@" || fail 'rendering hook output failed'
  REPLY=$SF_PRESENT_VIEWPORT_TEXT
}

# Standalone activity is an unsafe tail.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event activity_start
view 79 20
assert_equal '⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event assistant_start
sf_tui_event assistant_end
sf_tui_event activity_stop
view 79 20
assert_equal '' "$REPLY"

# Visible blocks replace activity; opaque blocks resume it.
sf_tui_event activity_start
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 before
sf_tui_event assistant_reasoning_opaque 1
view 79 20
[[ $REPLY == *before*$'\n\n⠃' ]] || fail "opaque activity did not resume: $REPLY"
sf_tui_event assistant_message_delta 2 after
sf_tui_event assistant_end
view 79 20
[[ $REPLY == *before*$'\n\nafter' ]] || fail "visible blocks were not rendered in order: $REPLY"
sf_tui_event activity_stop
sf_tui_reset

# Hook results replace their live view and settle it.
sf_tui_event activity_start
sf_tui_event hook_call session_start /hooks/project/run $'project · Inspecting\nfiles' 0
SF_PRESENT_STYLE[hook]='fg=#111111'
SF_PRESENT_STYLE[activity]='fg=#222222'
view 79 20
assert_equal $'ℹ project · Inspecting\n│ files\n╰ ⠃' "$REPLY"
(( ${SF_PRESENT_VIEWPORT_HIGHLIGHTS[(Ie)fg=#111111]} )) ||
  fail 'hook notice did not retain its own style'
(( ${SF_PRESENT_VIEWPORT_HIGHLIGHTS[(Ie)fg=#222222]} )) ||
  fail 'hook activity did not use the agent style'
sf_tui_event hook_result session_start /hooks/project/run $'project · Ready\nresult' 0
view 79 20
assert_equal $'ℹ project · Ready\n╰ result\n\n⠃' "$REPLY"
assert_equal 2 "$SF_PRESENT_SAFE_ROWS"
unset 'SF_PRESENT_STYLE[hook]' 'SF_PRESENT_STYLE[activity]'
sf_tui_event activity_stop

# An empty final view retracts its live predecessor.
sf_tui_reset
sf_tui_event activity_start
sf_tui_event hook_call stop /hooks/check/run 'check' 0
sf_tui_event hook_result stop /hooks/check/run '' -1
view 79 20
assert_equal '⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event activity_stop

# A silent script leaves its running view for the next result to retract.
sf_tui_reset
sf_tui_event activity_start
sf_tui_event hook_call session_start /hooks/silent/run 'silent · Working' 0
sf_tui_event hook_result session_start /hooks/loud/run $'loud\nresult' 0
view 79 20
assert_equal $'ℹ loud\n╰ result\n\n⠃' "$REPLY"
sf_tui_event activity_stop

# Replayed results append already settled.
sf_tui_reset
sf_tui_event hook_result user_prompt_submit /hooks/prompt/run $'prompt\nfirst\nsecond' 0
view 79 20
assert_equal $'ℹ prompt\n│ first\n╰ second' "$REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"

# A hook that fed the model is marked as reference material and previewed.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=1
sf_tui_event hook_result session_start /hooks/probe/run $'probe\nfirst\nsecond\nthird' 0 1
view 79 20
assert_equal $'↪ probe\n│ first\n╰ … ~6 tokens' "$REPLY"

# A hook that spoke only to the reader is a notice, shown whole.
sf_tui_reset
sf_tui_event hook_result stop /hooks/check/run $'check\nfirst\nsecond\nthird' 0 0
view 79 20
assert_equal $'ℹ check\n│ first\n│ second\n╰ third' "$REPLY"

# A zero budget keeps the identity row alone.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=0
sf_tui_event hook_result user_prompt_submit /hooks/prompt/run $'prompt\nfirst\nsecond' 0 1
view 79 20
assert_equal $'↪ prompt\n╰ … ~5 tokens' "$REPLY"
SF_PRESENT_PREVIEW_CONTEXT=full

# Errors close the turn before the next numbered section.
sf_tui_reset
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 partial
sf_tui_event error Failed $'detail one\ndetail two'
view 79 20
[[ $REPLY == *$'partial\n\n✕ Failed\n  detail one\n  detail two' ]] ||
  fail "error output: $REPLY"
assert_equal 7 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event user retry
view 79 20
[[ $REPLY == *$'─ user '*$' 2 ─\n\nretry' ]] || fail "post-error section: $REPLY"

# Tall settled hooks can drain through a short terminal budget.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event hook_result stop /hooks/check/run $'check\none\ntwo\nthree\nfour' 0
sf_tui_transcript 20 4 || fail 'rendering a tall hook result failed'
sf_tui_terminal_stage || fail 'staging a tall hook result failed'
sf_tui_terminal_finish || fail 'committing a tall hook result failed'
sf_tui_terminal_restore
view 20 20
[[ $REPLY == *four ]] || fail "tall hook result did not drain: $REPLY"
