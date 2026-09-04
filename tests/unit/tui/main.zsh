#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source tui/main.zsh

# The client receives a resolved session and runs its turns through exec.
typeset seen_session='' seen_presentation='' seen_initial=''
typeset seen_mode='' seen_draft=''
sf_tui_controller() {
  seen_session=$1
  seen_presentation=$2
  seen_initial=$3
  seen_mode=$4
  seen_draft=$5
}
typeset -g SF_ENTRY="$ROOT/bin/shellfish"
sf_tui_run /sessions/open.jsonl '{"theme":"dark"}' prompt startup sketch 0
assert_equal /sessions/open.jsonl "$seen_session"
assert_equal '{"theme":"dark"}' "$seen_presentation"
assert_equal startup "$seen_mode"
assert_equal prompt "$seen_initial"
assert_equal sketch "$seen_draft"
assert_equal "$SF_ENTRY exec --jsonl --session /sessions/open.jsonl" \
  "${SF_TUI_TRANSPORT_COMMAND[*]}"

# A controller failure surfaces its status and presentation error.
integer run_status=0
sf_tui_controller() {
  SF_PRESENT_ERROR='controller stopped'
  return 3
}
sf_tui_run /sessions/open.jsonl '{}' '' resume '' 0 || run_status=$?
(( run_status == 3 ))
assert_equal 'controller stopped' "$SF_TUI_ERROR"
