#!/usr/bin/env zsh

source "${0:A:h:h:h:h}/_helpers.zsh"
sf_test_source libexec/tui/render/formatters.zsh libexec/tui/render/highlights.zsh \
  libexec/tui/render/text.zsh libexec/tui/render/wrap.zsh \
  libexec/tui/render/messages.zsh libexec/tui/render/hooks.zsh \
  libexec/tui/render/tools.zsh libexec/tui/render/terminal.zsh \
  libexec/tui/render/view.zsh

typeset -gi COLUMNS=80 LINES=10
typeset -g BUFFER='' CURSOR=0 PREDISPLAY='' POSTDISPLAY=''

view() {
  sf_tui_transcript "${1:-80}" 100 || fail 'rendering tools failed'
  REPLY=$SF_PRESENT_VIEWPORT_TEXT
}

assert_tail() {
  [[ $REPLY == *"$1" ]] || fail "expected tail: $1\nactual: $REPLY"
}

has_span() {
  local style=$1
  integer width=$2 index
  for (( index = 1; index <= ${#SF_PRESENT_VIEWPORT_HIGHLIGHTS}; index += 3 )); do
    [[ ${SF_PRESENT_VIEWPORT_HIGHLIGHTS[index + 2]} == "$style" ]] || continue
    (( SF_PRESENT_VIEWPORT_HIGHLIGHTS[index + 1] -
      SF_PRESENT_VIEWPORT_HIGHLIGHTS[index] == width )) && return 0
  done
  return 1
}

# A call replaces standalone activity and owns a final heading/body followed by
# one pending result. Only the call rows are safe while execution is pending.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event activity_start
sf_tui_event assistant_start
sf_tui_event assistant_tool_call_delta 0
sf_tui_event assistant_end
sf_tui_event tool_call call_1 shell 'make test' 'build · unsandboxed' sh
assert_equal 'tool_call,tool_result' "${(j:,:)SF_PRESENT_KIND}"
assert_equal 2 "$SF_PRESENT_LIVE"
view
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n⛭ shell · build · unsandboxed\n│ make test\n╰ ⠃' "$REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_PREFIX"

# The pending tail validates the next durable result without an ID-indexed
# store. A mismatch changes nothing; settlement resumes standalone activity.
if sf_tui_event tool_result wrong 0 result plain; then
  fail 'a result settled the wrong pending call'
fi
assert_equal 2 "$SF_PRESENT_LIVE"
sf_tui_event tool_result call_1 1 $'failed\ndetail' plain '' sandbox_denial
assert_equal 'tool_call,tool_result,activity' "${(j:,:)SF_PRESENT_KIND}"
view
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n⛭ shell · build · unsandboxed\n│ make test\n╰ failed\n  detail\n  exit 1 · sandbox denial detected\n\n⠃' "$REPLY"
assert_equal 7 "$SF_PRESENT_SAFE_PREFIX"
sf_tui_event activity_stop

# Permission mutates only the pending result: its activity disappears while
# the prompt owns interaction, then returns after the decision is delivered.
sf_tui_reset
sf_tui_event activity_start
sf_tui_event tool_call permission shell pwd '' sh
sf_tui_event tool_permission
view
assert_tail $'⛭ shell\n│ pwd'
assert_equal 4 "$SF_PRESENT_SAFE_PREFIX"
sf_tui_event tool_permission_clear
view
assert_tail $'⛭ shell\n│ pwd\n╰ ⠃'
sf_tui_event tool_result permission 126 'sandbox bypass denied' plain
sf_tui_event hook_result post post_tool_use '' 'after denial'
assert_equal 'tool_call,tool_result,hook_user_context,activity' \
  "${(j:,:)SF_PRESENT_KIND}"
view
[[ $REPLY == *$'╰ sandbox bypass denied\n  exit 126\n\nℹ post · post_tool_use\n  after denial\n\n⠃' ]] ||
  fail "denied result order: $REPLY"
sf_tui_event activity_stop

# Zero previews collapse tool content into formatter-owned rows. A completed
# empty hidden result still closes its call rail.
sf_tui_reset
SF_PRESENT_PREVIEW_TOOL_CALL=0
SF_PRESENT_PREVIEW_TOOL_RESULT=0
sf_tui_event tool_call zero shell 'make test' '' sh
SF_PRESENT_STYLE=( tool_result tool divider rail clamp muted )
view
assert_tail $'⛭ shell\n╰ ⠃'
[[ "${(j: :)SF_PRESENT_VIEWPORT_HIGHLIGHTS}" != *muted* ]] ||
  fail 'pending activity was styled as omitted content'
sf_tui_event tool_result zero 1 $'failure\ndetail' plain
view
assert_tail $'⛭ shell\n╰ … · exit 1'
[[ "${(j: :)SF_PRESENT_VIEWPORT_HIGHLIGHTS}" == *muted* ]] ||
  fail 'collapsed result lost its clamp style'
SF_PRESENT_STYLE=()
sf_tui_reset
sf_tui_event tool_call empty read_file path '' plain
sf_tui_event tool_result empty hidden '' plain
view
assert_tail $'⛭ read_file\n╰'
SF_PRESENT_PREVIEW_TOOL_CALL=full
SF_PRESENT_PREVIEW_TOOL_RESULT=full

# Independent call/result previews clamp wrapped rows and count the complete
# result. A result marked full overrides the configured result limit.
sf_tui_reset
SF_PRESENT_PREVIEW_TOOL_CALL=1
SF_PRESENT_PREVIEW_TOOL_RESULT=1
sf_tui_event tool_call preview shell $'first row\nsecond row' '' sh
sf_tui_event tool_result preview 1 $'result one\nresult two\nresult three' plain
view
assert_tail $'⛭ shell\n│ first row\n│ …\n╰ result one\n  … ~9 tokens · exit 1'
sf_tui_reset
sf_tui_event tool_call full edit_file path '' plain
sf_tui_event tool_result full hidden $'one\ntwo\nthree' file_diff full
view
assert_tail $'⛭ edit_file\n│ path\n╰ one\n  two\n  three'
SF_PRESENT_PREVIEW_TOOL_CALL=full
SF_PRESENT_PREVIEW_TOOL_RESULT=full

# Diff syntax follows wrapped result rows and pads background spans to the
# terminal width, including the closing rail.
sf_tui_reset
SF_PRESENT_STYLE=( tool_call tool tool_result tool divider rail \
  'syntax.added' 'fg=green,bg=darkgreen' \
  'syntax.removed' 'fg=red,bg=darkred' )
sf_tui_event tool_call diff edit_file path '' plain
sf_tui_event tool_result diff hidden $'-old\n+alpha beta' file_diff full
view 12
[[ $REPLY == *$'╰ -old      \n  +alpha    \n  beta      ' ]] ||
  fail "diff result: $REPLY"
has_span 'fg=red,bg=darkred' 12 ||
  fail 'removed diff row did not fill its background'
has_span 'fg=green,bg=darkgreen' 12 ||
  fail 'added diff rows did not fill their background'
SF_PRESENT_STYLE=()

# A turn failure settles a pending result before appending its error.
sf_tui_reset
sf_tui_event tool_call abandoned shell run '' sh
sf_tui_event error Failed broken end
assert_equal 'tool_call,tool_result,error' "${(j:,:)SF_PRESENT_KIND}"
assert_equal 0 "$SF_PRESENT_LIVE"
view
assert_tail $'⛭ shell\n│ run\n╰\n\n✕ Failed\n  broken'
