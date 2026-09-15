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

# A call is one live entry whose complete text is replaced by its result.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event activity_start
sf_tui_event assistant_start
sf_tui_event assistant_tool_call_delta 0
sf_tui_event assistant_end
sf_tui_event tool_call call_1 'shell · make test' shell 0
view
assert_tail $'⛭ shell · make test\n╰ ⠃'
assert_equal 0 "$SF_PRESENT_SAFE_ROWS"

sf_tui_event tool_result call_1 $'shell · failed\ndetail\nexit 1' shell 0
view
assert_tail $'⛭ shell · failed\n│ detail\n╰ exit 1\n\n⠃'
assert_equal 5 "$SF_PRESENT_SAFE_ROWS"
sf_tui_event activity_stop

# Lifecycle hook activity borrows the live tool block until the tool settles it.
sf_tui_reset
sf_tui_event activity_start
sf_tui_event tool_call hooked $'shell\nmake test' shell 0
sf_tui_event hook_call pre_tool_use /hooks/guard/run $'guard\nchecking' 0
view
assert_tail $'⛭ guard\n│ checking\n╰ ⠃'
sf_tui_event hook_call pre_tool_use /hooks/guard/run $'guard\napproved' 0
view
assert_tail $'⛭ guard\n│ approved\n╰ ⠃'
sf_tui_event tool_result hooked $'shell\nmake test\ndone' shell 0
view
assert_tail $'⛭ shell\n│ make test\n╰ done\n\n⠃'
sf_tui_event activity_stop

# A queued cancellation has no running activity, but its result is still complete.
sf_tui_reset
sf_tui_event tool_result queued 'shell · cancelled' shell 0
view
assert_tail $'⛭ shell · cancelled\n╰'

# Permission hides only the live spinner; normal rendering remains intact.
sf_tui_reset
sf_tui_event activity_start
sf_tui_event tool_call permission $'shell · pwd\nwaiting' shell 0
sf_tui_event tool_permission
view
assert_tail $'⛭ shell · pwd\n│ waiting'
sf_tui_event tool_permission_clear
view
assert_tail $'⛭ shell · pwd\n│ waiting\n╰ ⠃'
sf_tui_event tool_result permission 'shell · sandbox bypass denied' shell 0
view
assert_tail $'⛭ shell · sandbox bypass denied\n╰\n\n⠃'
sf_tui_event activity_stop

# Tool text is plain even when it resembles a diff.
sf_tui_reset
SF_PRESENT_STYLE=( tool tool divider rail
  'syntax.added' 'fg=green,bg=darkgreen'
  'syntax.removed' 'fg=red,bg=darkred' )
sf_tui_event tool_call diff 'edit_file · path' edit_file 0
sf_tui_event tool_result diff $'edit_file · path\n-old\n+new' edit_file 0
view 20
assert_tail $'⛭ edit_file · path\n│ -old\n╰ +new'
! has_style 'fg=red,bg=darkred' || fail 'tool text received diff highlighting'
! has_style 'fg=green,bg=darkgreen' || fail 'tool text received diff highlighting'
SF_PRESENT_STYLE=()

# Turn failures settle pending results.
sf_tui_reset
sf_tui_event tool_call abandoned 'shell · run' shell 0
sf_tui_event error Failed broken end
view
assert_tail $'⛭ shell · run\n╰\n\n✕ Failed\n  broken'

# Settled tools taller than the terminal budget drain in source order.
sf_tui_reset
sf_tui_terminal_reset
sf_tui_event tool_call tall 'shell · one' shell 0
sf_tui_event tool_result tall $'shell · one\ntwo\nthree\nfour\nfive' shell 0
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
assert_equal $'─ agent ──────── 1 ─\n\n⛭ shell · one\n│ two\n│ three\n│ four\n╰ five' \
  "${drained%$'\n'}"
