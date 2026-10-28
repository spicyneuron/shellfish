#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp session-mutation
sf_test_frozen_profile

typeset session="$tmp/session.jsonl" before profile
sf_test_session "$session"

# Project-scoped sessions and scratch are private within the Shellfish directory.
sf_session_select_path
[[ $REPLY == "${tmp:A}/shellfish/sessions/"*.jsonl ]]
[[ $(stat -f %Lp "$REPLY:h") == 700 ]]
sf_test_source lib/scratch.zsh
sf_scratch_root
[[ $REPLY == "${tmp:A}/shellfish/scratch" && $(stat -f %Lp "$REPLY") == 700 ]]

# Without SHELLFISH_DIR, the nearest .shellfish above the working directory
# wins, then ~/.shellfish.
(
  unset SHELLFISH_DIR
  export HOME="$tmp/home"
  mkdir -p "$tmp/flavor/.shellfish" "$tmp/flavor/project/nested" "$tmp/elsewhere"
  builtin cd -- "$tmp/flavor/project/nested"
  sf_environment_dir
  [[ $REPLY == "${tmp:A}/flavor/.shellfish" ]]
  builtin cd -- "$tmp/elsewhere"
  sf_environment_dir
  [[ $REPLY == "${tmp:A}/home/.shellfish" ]]
  SHELLFISH_DIR="$tmp/explicit" sf_environment_dir
  [[ $REPLY == "${tmp:A}/explicit" ]]
)

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
profile=$(jq -c '.sandbox.read=["/tmp/reference"] | .sandbox.write=["/tmp/reference"]' \
  <<<"$SF_TEST_PROFILE")
sf_session_replace_profile "$session" "$profile" || fail "$SF_SESSION_ERROR"
head -n 1 "$session" | jq -e '
  .profile.sandbox.read == ["/tmp/reference"] and
  .profile.sandbox.write == ["/tmp/reference"]
' >/dev/null
assert_equal "$before" "$(tail -n +2 "$session")"
[[ $(stat -f '%Lp' "$session") == 600 ]]

typeset unchanged=$(cat "$session")
if sf_session_replace_profile "$session" '{}'; then
  fail 'invalid profile replacement succeeded'
fi
assert_equal "$unchanged" "$(cat "$session")"

sf_session_read_profile "$session" || fail "$SF_SESSION_ERROR"
jq -e '.sandbox.read == ["/tmp/reference"]' <<<"$REPLY" >/dev/null

print -r -- ok
