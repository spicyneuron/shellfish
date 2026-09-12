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

# Hook activity replaces standalone activity in place.
sf_tui_event activity_start
sf_tui_event hook_activity session_start project Inspecting
sf_tui_event hook_activity user_prompt_submit prompt Checking
view 79 20
assert_equal $'ℹ Checking\n⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event hook_activity
view 79 20
assert_equal '⠃' "$REPLY"
sf_tui_event activity_stop

# Hook results append model context before user context.
sf_tui_event activity_start
sf_tui_event hook_activity user_prompt_submit prompt Running
sf_tui_event hook_result prompt 'user_prompt_submit · git status · status 0' \
  $'**branch**\nsecond line' $'local note\nnext'
view 79 20
assert_equal $'↪ prompt · user_prompt_submit · git status · status 0\n  **branch**\n  second line\n\nℹ prompt · user_prompt_submit · git status · status 0\n  local note\n  next\n\n⠃' "$REPLY"
assert_equal 7 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event activity_stop

# Only model context uses the preview limit.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=1
sf_tui_event hook_result hook test $'first\nsecond' $'third\nfourth'
view 79 20
assert_equal $'↪ hook · test\n  first\n  … ~3 tokens\n\nℹ hook · test\n  third\n  fourth' "$REPLY"
assert_equal 7 "$SF_PRESENT_SAFE_ROWS"
SF_PRESENT_PREVIEW_CONTEXT=full

# Zero previews collapse model context.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=0
sf_tui_event hook_result hook test $'first\nsecond' $'third\nfourth'
view 79 20
assert_equal $'↪ hook · test · ~3 tokens\n\nℹ hook · test\n  third\n  fourth' "$REPLY"
assert_equal 5 "$SF_PRESENT_SAFE_ROWS"
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

# Partial commits preserve Markdown fence state.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_STYLE=( hook_model_context context 'syntax.string' string 'syntax.fence' fence )
sf_tui_event hook_result hook test $'```sh\necho "alpha"\necho "beta"\necho "gamma"\n```'
sf_tui_transcript 20 4 || fail 'rendering a tall hook result failed'
sf_tui_terminal_stage || fail 'staging a tall hook result failed'
sf_tui_terminal_finish || fail 'committing a tall hook result failed'
sf_tui_terminal_restore
view 20 20
[[ "${(j: :)SF_PRESENT_VIEWPORT_HIGHLIGHTS}" == *string* ]] ||
  fail "partially committed hook context lost its fence state: $REPLY"
SF_PRESENT_STYLE=()
