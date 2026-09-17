#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp session-mutation
sf_test_runtime

typeset session="$tmp/session.jsonl" before runtime
sf_test_session "$session"

# Default sessions use a private project-scoped state directory.
typeset -g XDG_STATE_HOME="$tmp/state"
sf_session_select_path
[[ $REPLY == "$tmp/state/shellfish/sessions/"*.jsonl ]]
[[ $(stat -f %Lp "$REPLY:h") == 700 ]]

# Appends write one complete record and report the failing path plainly.
sf_session_append "$session" \
  '{"type":"user","content":[{"type":"text","text":"hello"}]}'
tail -n 1 "$session" | jq -e '.type == "user"' >/dev/null
mv "$session" "$session.saved"
mkdir "$session"
if sf_session_append "$session" '{"type":"error","user_text":"not written"}'; then
  fail 'append to an unavailable session file succeeded'
fi
[[ $SF_SESSION_ERROR == "cannot append session record: $session" ]]
rmdir "$session"
mv "$session.saved" "$session"

# Runtime replacement is atomic and leaves every durable record unchanged.
before=$(tail -n +2 "$session")
runtime=$(jq -c '.harness.sandbox_read_paths=["/tmp/reference"] |
  .harness.sandbox_write_paths=["/tmp/reference"]' <<<"$SF_TEST_RUNTIME")
sf_session_replace_runtime "$session" "$runtime" || fail "$SF_SESSION_ERROR"
head -n 1 "$session" | jq -e '
  .runtime.harness.sandbox_read_paths == ["/tmp/reference"] and
  .runtime.harness.sandbox_write_paths == ["/tmp/reference"]
' >/dev/null
assert_equal "$before" "$(tail -n +2 "$session")"
[[ $(stat -f '%Lp' "$session") == 600 ]]

typeset unchanged=$(cat "$session")
if sf_session_replace_runtime "$session" '{}'; then
  fail 'invalid runtime replacement succeeded'
fi
assert_equal "$unchanged" "$(cat "$session")"

sf_session_read_runtime "$session" || fail "$SF_SESSION_ERROR"
jq -e '.harness.sandbox_read_paths == ["/tmp/reference"]' <<<"$REPLY" >/dev/null

print -r -- ok
