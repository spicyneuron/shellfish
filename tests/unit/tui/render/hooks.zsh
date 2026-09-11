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

# Standalone activity is an unsafe tail and disappears when content arrives.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event activity_start
assert_equal activity "$SF_PRESENT_KIND[1]"
view 79 20
assert_equal '⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_PREFIX"
sf_tui_event assistant_start
assert_equal message "${(j:,:)SF_PRESENT_KIND}"
sf_tui_event assistant_end
assert_equal activity "${(j:,:)SF_PRESENT_KIND}"
sf_tui_event activity_stop
assert_equal 0 "${#SF_PRESENT_KIND}"

# A nonvisual assistant block resumes standalone activity, and the next visible
# block retracts it before opening its own live formatter.
sf_tui_event activity_start
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 before
sf_tui_event assistant_reasoning_opaque 1
assert_equal 'message,activity' "${(j:,:)SF_PRESENT_KIND}"
sf_tui_event assistant_message_delta 2 after
assert_equal 'message,message' "${(j:,:)SF_PRESENT_KIND}"
sf_tui_event assistant_end
assert_equal 'message,message,activity' "${(j:,:)SF_PRESENT_KIND}"
sf_tui_event activity_stop
sf_tui_reset

# Hook activity replaces standalone activity, updates in place, and leaves no
# spacing behind when a displayed hook completes without output.
SF_PRESENT_STYLE=( hook_activity muted )
sf_tui_event activity_start
sf_tui_event hook_activity session_start project Inspecting
assert_equal hook_activity "${(j:,:)SF_PRESENT_KIND}"
sf_tui_event hook_activity user_prompt_submit prompt Checking
assert_equal 1 "${#SF_PRESENT_KIND}"
view 79 20
assert_equal $'Checking\n⠃' "$REPLY"
assert_equal 0 "$SF_PRESENT_SAFE_PREFIX"
[[ "${(j: :)SF_PRESENT_VIEWPORT_HIGHLIGHTS}" == *'muted,bold'* ]] ||
  fail 'hook activity label lost its emphasis'
sf_tui_event hook_activity
assert_equal activity "${(j:,:)SF_PRESENT_KIND}"
view 79 20
assert_equal '⠃' "$REPLY"
sf_tui_event activity_stop
assert_equal 0 "${#SF_PRESENT_KIND}"
SF_PRESENT_STYLE=()

# A result removes only current activity and appends model output before user
# output. Both complete formatters are immediately safe.
sf_tui_event activity_start
sf_tui_event hook_activity user_prompt_submit prompt Running
sf_tui_event hook_result prompt 'user_prompt_submit · git status · status 0' \
  $'**branch**\nsecond line' $'local note\nnext'
assert_equal 'hook_model_context,hook_user_context,activity' "${(j:,:)SF_PRESENT_KIND}"
view 79 20
assert_equal $'↪ prompt · user_prompt_submit · git status · status 0\n  **branch**\n  second line\n\nℹ prompt · user_prompt_submit · git status · status 0\n  local note\n  next\n\n⠃' "$REPLY"
assert_equal 7 "$SF_PRESENT_SAFE_PREFIX"
sf_tui_event activity_stop

# Model context uses the context preview and counts the whole content. User
# context is the script's own message to the user and is never clamped.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=1
sf_tui_event hook_result hook test $'first\nsecond' $'third\nfourth'
view 79 20
assert_equal $'↪ hook · test\n  first\n  … ~3 tokens\n\nℹ hook · test\n  third\n  fourth' "$REPLY"
assert_equal 7 "$SF_PRESENT_SAFE_PREFIX"
SF_PRESENT_PREVIEW_CONTEXT=full

# A zero-row preview collapses the whole-content estimate into its heading.
sf_tui_reset
SF_PRESENT_PREVIEW_CONTEXT=0
sf_tui_event hook_result hook test $'first\nsecond' $'third\nfourth'
view 79 20
assert_equal $'↪ hook · test · ~3 tokens\n\nℹ hook · test\n  third\n  fourth' "$REPLY"
assert_equal 5 "$SF_PRESENT_SAFE_PREFIX"
SF_PRESENT_PREVIEW_CONTEXT=full

# Model context is Markdown-styled; user context remains literal plain text.
sf_tui_reset
SF_PRESENT_STYLE=( hook_model_context context hook_user_context muted
  'syntax.strong' bold )
sf_tui_event hook_result hook test '**model**' '**user**'
view 79 20
[[ "${(j: :)SF_PRESENT_VIEWPORT_HIGHLIGHTS}" == *'bold'* ]] ||
  fail 'model context lost Markdown styling'
integer bold_count=${#${(M)SF_PRESENT_VIEWPORT_HIGHLIGHTS:#bold}}
assert_equal 1 "$bold_count"
SF_PRESENT_STYLE=()

# Errors close live output, style their outcome and detail, and force the next
# user record to open a fresh numbered role section.
sf_tui_reset
SF_PRESENT_STYLE=( error errorstyle )
sf_tui_event assistant_start
sf_tui_event assistant_message_delta 0 partial
sf_tui_event error Failed $'detail one\ndetail two'
assert_equal 'message,error' "${(j:,:)SF_PRESENT_KIND}"
view 79 20
[[ $REPLY == *$'partial\n\n✕ Failed\n  detail one\n  detail two' ]] ||
  fail "error output: $REPLY"
assert_equal 7 "$SF_PRESENT_SAFE_PREFIX"
[[ "${(j: :)SF_PRESENT_VIEWPORT_HIGHLIGHTS}" == *errorstyle* ]] ||
  fail 'error output lost its style'
SF_PRESENT_STYLE=()
sf_tui_event user retry
assert_equal user "$SF_PRESENT_ROLE[-1]"
assert_equal 2 "$SF_PRESENT_SECTION[-1]"

# A hook result taller than one commit rescans from the state its committed
# prefix reached, so the rows that follow are still inside the fence.
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
