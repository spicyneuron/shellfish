#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh \
  libexec/tui/render/messages.zsh libexec/tui/render/notices.zsh \
  libexec/tui/render/execution.zsh \
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
sf_tui_event hook_call h1 $'project · Inspecting\nfiles' project notice
SF_PRESENT_STYLE[execution]='fg=#111111'
SF_PRESENT_STYLE[activity]='fg=#222222'
view 79 20
assert_equal $'ℹ project · Inspecting\n│ files\n╰ ⠃' "$REPLY"
(( ${SF_PRESENT_VIEWPORT_HIGHLIGHTS[(Ie)fg=#111111]} )) ||
  fail 'hook notice did not retain its own style'
(( ${SF_PRESENT_VIEWPORT_HIGHLIGHTS[(Ie)fg=#222222]} )) ||
  fail 'hook activity did not use the agent style'
sf_tui_event hook_result h1 $'project · Ready\nresult' project notice
view 79 20
assert_equal $'ℹ project · Ready\n╰ result\n\n⠃' "$REPLY"
assert_equal 2 "$SF_PRESENT_SAFE_ROWS"
unset 'SF_PRESENT_STYLE[execution]' 'SF_PRESENT_STYLE[activity]'
sf_tui_event activity_stop

# An empty final view retracts its live predecessor.
sf_tui_reset
sf_tui_event activity_start
sf_tui_event hook_call h1 'check' check notice
sf_tui_event hook_result h1 '' check notice
view 79 20
assert_equal '⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event activity_stop

# A later hook replaces a silent script's running view.
sf_tui_reset
sf_tui_event activity_start
sf_tui_event hook_call h1 'silent · Working' silent notice
sf_tui_event hook_call h1 'loud · Working' loud notice
sf_tui_event hook_result h1 $'loud\nresult' loud notice
view 79 20
assert_equal $'ℹ loud\n╰ result\n\n⠃' "$REPLY"
sf_tui_event activity_stop

# A following durable event retains a silent script's running view.
sf_tui_reset
sf_tui_event hook_call h1 'silent · Working' silent notice
sf_tui_event user ready
view 79 20
[[ $REPLY == $'ℹ silent · Working\n╰\n\n─ user '*$' 1 ─\n\nready' ]] ||
  fail "following message did not retain hook view: $REPLY"

# Replayed results append already settled.
sf_tui_reset
sf_tui_event hook_result h1 $'prompt\nfirst\nsecond' prompt notice
view 79 20
assert_equal $'ℹ prompt\n│ first\n╰ second' "$REPLY"
assert_equal 3 "$SF_PRESENT_SAFE_ROWS"

# Hook output is clamped to the configured context budget.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=1
sf_tui_event hook_result h1 $'probe\nfirst\nsecond\nthird' probe context
view 79 20
assert_equal $'↪ probe\n│ first\n╰ … ~6 tokens' "$REPLY"

# A zero budget keeps the identity row alone.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=0
sf_tui_event hook_result h1 $'prompt\nfirst\nsecond' prompt context
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
sf_tui_event hook_result h1 $'check\none\ntwo\nthree\nfour' check notice
sf_tui_transcript 20 4 || fail 'rendering a tall hook result failed'
sf_tui_terminal_stage || fail 'staging a tall hook result failed'
sf_tui_terminal_finish || fail 'committing a tall hook result failed'
sf_tui_terminal_restore
view 20 20
[[ $REPLY == *four ]] || fail "tall hook result did not drain: $REPLY"
