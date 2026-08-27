#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source chat/main.zsh
sf_test_tmp ui-main

# Runtime overrides cannot be used with an existing non-empty session.
typeset existing="$tmp/existing.jsonl"
print -r -- '{}' >"$existing"
sf_session_select_path() { REPLY=$1; }
integer start_status=0
sf_chat_run "$existing" '' '' '' '{}' '' 1 0 0 || start_status=$?
(( start_status == 2 ))
[[ $SF_CHAT_ERROR == 'runtime overrides cannot be used with an existing session' ]]

# Existing chat restores current presentation before entering the controller.
typeset lean_session="$tmp/lean.jsonl" lean_called='' lean_runtime=''
typeset lean_initial='' lean_session_mode='' lean_presentation=''
integer restore_calls=0 resolve_calls=0
print -r -- '{}' >"$lean_session"
sf_runtime_restore_presentation() {
  (( ++restore_calls ))
  SF_PRESENTATION='{"source":"restore"}'
}
sf_runtime_resolve() {
  (( ++resolve_calls ))
  SF_PRESENTATION='{"source":"resolve"}'
  REPLY='{"resolved":true}'
}
sf_chat_controller() {
  lean_called=$1
  lean_runtime=$2
  lean_initial=$3
  lean_session_mode=$4
  lean_presentation=$SF_PRESENTATION
}
sf_chat_run "$lean_session" '' '' '' '{}' '' 0 0 0 prompt
assert_equal "$lean_session" "$lean_called"
assert_equal '{}' "$lean_runtime"
assert_equal prompt "$lean_initial"
assert_equal resume "$lean_session_mode"
assert_equal '{"source":"restore"}' "$lean_presentation"
(( restore_calls == 1 && resolve_calls == 0 ))

# New chat uses the presentation produced with its runtime and does not restore it.
typeset new_session="$tmp/new.jsonl"
restore_calls=0
lean_called=''
sf_hooks_state_create() { return 0; }
sf_session_prepare() { return 0; }
sf_hooks_session_start() { return 0; }
sf_session_create() { : >"$SF_SESSION_SELECTED"; }
sf_hooks_state_cleanup() { return 0; }
sf_chat_run "$new_session" '' '' '' '{}' '' 0 0 0
assert_equal "$new_session" "$lean_called"
assert_equal '{"resolved":true}' "$lean_runtime"
assert_equal startup "$lean_session_mode"
assert_equal '{"source":"resolve"}' "$lean_presentation"
(( restore_calls == 0 && resolve_calls == 1 ))
