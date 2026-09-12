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

has_style() {
  (( ${SF_PRESENT_VIEWPORT_HIGHLIGHTS[(Ie)$1]} ))
}

# A pending result keeps only its call rows safe.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event activity_start
sf_tui_event assistant_start
sf_tui_event assistant_tool_call_delta 0
sf_tui_event assistant_end
sf_tui_event tool_call call_1 shell 'make test' 'build · unsandboxed' sh
view
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n⛭ shell · build · unsandboxed\n│ make test\n╰ ⠃' "$REPLY"
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"

sf_tui_event tool_result call_1 1 $'failed\ndetail' plain '' sandbox_denial
view
assert_equal $'─ agent ──────────────────────────────────────────────────────────────────── 1 ─\n\n⛭ shell · build · unsandboxed\n│ make test\n╰ failed\n  detail\n  exit 1 · sandbox denial detected\n\n⠃' "$REPLY"
assert_equal 7 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event activity_stop

# Permission temporarily hides pending-result activity.
sf_tui_reset
sf_tui_event activity_start
sf_tui_event tool_call permission shell pwd '' sh
sf_tui_event tool_permission
view
assert_tail $'⛭ shell\n│ pwd'
assert_equal 4 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event tool_permission_clear
view
assert_tail $'⛭ shell\n│ pwd\n╰ ⠃'
sf_tui_event tool_result permission 126 'sandbox bypass denied' plain
sf_tui_event hook_result post post_tool_use '' 'after denial'
view
[[ $REPLY == *$'╰ sandbox bypass denied\n  exit 126\n\nℹ post · post_tool_use\n  after denial\n\n⠃' ]] ||
  fail "denied result order: $REPLY"
sf_tui_event activity_stop

# Zero previews collapse content but preserve the call rail.
sf_tui_reset
SF_PRESENT_PREVIEW_TOOL_CALL=0
SF_PRESENT_PREVIEW_TOOL_RESULT=0
sf_tui_event tool_call zero shell 'make test' '' sh
view
assert_tail $'⛭ shell\n╰ ⠃'
sf_tui_event tool_result zero 1 $'failure\ndetail' plain
view
assert_tail $'⛭ shell\n╰ … · exit 1'
sf_tui_reset
sf_tui_event tool_call empty read_file path '' plain
sf_tui_event tool_result empty hidden '' plain
view
assert_tail $'⛭ read_file\n╰'
SF_PRESENT_PREVIEW_TOOL_CALL=full
SF_PRESENT_PREVIEW_TOOL_RESULT=full

# Call and result previews clamp independently.
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

# Diff background colors fill each changed row.
sf_tui_reset
SF_PRESENT_STYLE=( tool_call tool tool_result tool divider rail
  'syntax.added' 'fg=green,bg=darkgreen'
  'syntax.removed' 'fg=red,bg=darkred' )
sf_tui_event tool_call diff edit_file path '' plain
sf_tui_event tool_result diff hidden $'-old\n+new' file_diff full
view 12
[[ $REPLY == *$'╰ -old      \n  +new      ' ]] || fail "diff result: $REPLY"
has_style 'fg=red,bg=darkred' || fail 'removed diff background was not rendered'
has_style 'fg=green,bg=darkgreen' || fail 'added diff background was not rendered'
SF_PRESENT_STYLE=()

# Turn failures settle pending results.
sf_tui_reset
sf_tui_event tool_call abandoned shell run '' sh
sf_tui_event error Failed broken end
view
assert_tail $'⛭ shell\n│ run\n╰\n\n✕ Failed\n  broken'

# Tall tools drain once in source order.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event tool_call tall shell 'make test' '' sh
sf_tui_event tool_result tall 0 $'one\ntwo\nthree\nfour' plain
typeset drained=''
integer batch
for batch in 1 2 3; do
  sf_tui_transcript 20 4 || fail 'rendering a tall tool failed'
  (( ! SF_PRESENT_SAFE_ROWS )) || {
    sf_tui_terminal_stage || fail 'staging a tall tool failed'
    sf_tui_terminal_finish || fail 'committing a tall tool failed'
    drained+=$PREDISPLAY$'\n'
    sf_tui_terminal_restore
  }
done
assert_equal $'─ agent ──────── 1 ─\n\n⛭ shell\n│ make test\n╰ one\n  two\n  three\n  four\n  exit 0' \
  "${drained%$'\n'}"

# Preview clamps do not drain windows.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_PREVIEW_TOOL_RESULT=1
sf_tui_event tool_call clamped shell 'make test' '' sh
sf_tui_event tool_result clamped 0 $'one\ntwo\nthree' plain
sf_tui_transcript 20 20 || fail 'rendering a clamped tool failed'
sf_tui_terminal_stage || fail 'staging a clamped tool failed'
sf_tui_terminal_finish || fail 'committing a clamped tool failed'
[[ $PREDISPLAY == *$'╰ one\n  … ~'* && $PREDISPLAY != *two* ]] ||
  fail "clamped tool commit: $PREDISPLAY"
SF_PRESENT_PREVIEW_TOOL_RESULT=full

# Committed rows spend the preview budget.
sf_tui_reset
sf_tui_terminal_reset
SF_PRESENT_PREVIEW_TOOL_RESULT=2
sf_tui_event tool_call spent shell 'make test' '' sh
sf_tui_event tool_result spent 0 $'one\ntwo\nthree\nfour' plain
sf_tui_transcript 20 6 || fail 'rendering a spent preview failed'
sf_tui_terminal_stage || fail 'staging a spent preview failed'
sf_tui_terminal_finish || fail 'committing a spent preview failed'
[[ $PREDISPLAY == *$'╰ one\n  two' && $PREDISPLAY != *three* ]] ||
  fail "spent preview commit: $PREDISPLAY"
sf_tui_terminal_restore
view
assert_equal $'  … ~5 tokens · exit\n0' "$REPLY"
SF_PRESENT_PREVIEW_TOOL_RESULT=full
