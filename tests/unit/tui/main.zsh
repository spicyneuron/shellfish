#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source tui/main.zsh

# The client receives a resolved session and runs its turns through exec.
typeset chat_session='' chat_runtime='' chat_initial='' chat_mode='' chat_draft=''
sf_chat_controller() {
  chat_session=$1
  chat_runtime=$2
  chat_initial=$3
  chat_mode=$4
  chat_draft=$5
}
typeset -g SF_ENTRY="$ROOT/bin/shellfish"
sf_chat_run /sessions/open.jsonl '{"resolved":true}' startup 0 prompt sketch
assert_equal /sessions/open.jsonl "$chat_session"
assert_equal '{"resolved":true}' "$chat_runtime"
assert_equal startup "$chat_mode"
assert_equal prompt "$chat_initial"
assert_equal sketch "$chat_draft"
assert_equal "$SF_ENTRY exec --jsonl --session /sessions/open.jsonl" \
  "${SF_CHAT_TRANSPORT_COMMAND[*]}"

# A controller failure surfaces its status and presentation error.
integer chat_status=0
sf_chat_controller() {
  SF_PRESENT_ERROR='controller stopped'
  return 3
}
sf_chat_run /sessions/open.jsonl '{}' resume 0 '' '' || chat_status=$?
(( chat_status == 3 ))
assert_equal 'controller stopped' "$SF_CHAT_ERROR"
