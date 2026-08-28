#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source session/startup.zsh
sf_test_tmp startup

typeset calls='' prepared_runtime='' prepared_system='' started_session=''
typeset -ga created_context=()
SF_HOOK_CONTEXT_RECORDS=('context one' 'context two')

sf_hooks_state_create() { calls+=state,; SHELLFISH_STATE_DIR=$tmp/state; mkdir "$SHELLFISH_STATE_DIR"; }
sf_session_prepare() {
  calls+=prepare,
  prepared_runtime=$1
  prepared_system=$2
}
sf_hooks_session_start() { calls+=hook,; started_session=$1; }
sf_session_create() { calls+=create,; created_context=( "$@" ); }
sf_hooks_state_cleanup() { calls+=cleanup,; rm -rf -- "$SHELLFISH_STATE_DIR"; unset SHELLFISH_STATE_DIR; }

sf_session_startup_create "$tmp/session.jsonl" runtime system
assert_equal 'state,prepare,hook,create,cleanup,' "$calls"
assert_equal "$tmp/session.jsonl" "$SF_SESSION_PATH"
assert_equal runtime "$prepared_runtime"
assert_equal system "$prepared_system"
assert_equal "$tmp/session.jsonl" "$started_session"
assert_equal 'context one context two' "${created_context[*]}"
[[ -z ${SHELLFISH_STATE_DIR-} ]]

calls=''
sf_session_prepare() { calls+=prepare,; SF_SESSION_ERROR='prepare failed'; return 1; }
if sf_session_startup_create "$tmp/failed.jsonl" runtime; then
  fail 'failed session preparation succeeded'
fi
assert_equal 'state,prepare,cleanup,' "$calls"
assert_equal 'prepare failed' "$SF_SESSION_STARTUP_ERROR"
[[ -z ${SHELLFISH_STATE_DIR-} ]]
