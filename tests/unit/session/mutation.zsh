#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session.zsh
sf_test_tmp session-mutation
sf_test_frozen_profile

typeset session="$tmp/session.jsonl" before profile
sf_test_session "$session"

# Default sessions use a private project-scoped state directory.
sf_session_select_path
[[ $REPLY == "$tmp/state/shellfish/sessions/"*.jsonl ]]
[[ $(stat -f %Lp "$REPLY:h") == 700 ]]

# Specific overrides win over SHELLFISH_STATE_DIR, which wins over XDG.
(
  export SHELLFISH_STATE_DIR="$tmp/custom-state"
  sf_session_directory
  [[ $REPLY == "$tmp/custom-state/sessions/"* ]]
  SHELLFISH_SESSIONS_DIR="$tmp/custom-sessions" sf_session_directory
  [[ $REPLY == "$tmp/custom-sessions/"* ]]
  sf_test_source lib/scratch.zsh
  sf_scratch_root
  [[ $REPLY == "${tmp:A}/custom-state/scratch" ]]
  SHELLFISH_SCRATCH_DIR="$tmp/custom-scratch" sf_scratch_root
  [[ $REPLY == "${tmp:A}/custom-scratch" && $(stat -f %Lp "$REPLY") == 700 ]]
  SHELLFISH_CONFIG_DIR="$tmp/custom-config" sf_environment_config_dir
  [[ $REPLY == "${tmp:A}/custom-config" ]]
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
profile=$(jq -c '.sandbox_read_paths=["/tmp/reference"] |
  .sandbox_write_paths=["/tmp/reference"]' <<<"$SF_TEST_PROFILE")
sf_session_replace_profile "$session" "$profile" || fail "$SF_SESSION_ERROR"
head -n 1 "$session" | jq -e '
  .profile.sandbox_read_paths == ["/tmp/reference"] and
  .profile.sandbox_write_paths == ["/tmp/reference"]
' >/dev/null
assert_equal "$before" "$(tail -n +2 "$session")"
[[ $(stat -f '%Lp' "$session") == 600 ]]

typeset unchanged=$(cat "$session")
if sf_session_replace_profile "$session" '{}'; then
  fail 'invalid profile replacement succeeded'
fi
assert_equal "$unchanged" "$(cat "$session")"

sf_session_read_profile "$session" || fail "$SF_SESSION_ERROR"
jq -e '.sandbox_read_paths == ["/tmp/reference"]' <<<"$REPLY" >/dev/null

print -r -- ok
