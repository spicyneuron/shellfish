#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source session/startup.zsh
sf_test_tmp startup
sf_test_runtime

typeset failed="$tmp/failed.jsonl" hook="$tmp/failing-hook" marker="$tmp/state-marker"
cat >"$hook" <<'ZSH'
#!/usr/bin/env zsh
[[ $1 == session_start && -d $SHELLFISH_STATE_DIR ]] || exit 2
print -r -- "$SHELLFISH_STATE_DIR" >"$SF_TEST_STATE_MARKER"
print -u2 -r -- 'startup detail'
exit 9
ZSH
chmod +x "$hook"
SF_TEST_RUNTIME=$(jq -c --arg hook "$hook" '.harness.session_start=[$hook]' \
  <<<"$SF_TEST_RUNTIME")
export XDG_STATE_HOME="$tmp/state" SF_TEST_STATE_MARKER="$marker"

# A real hook failure prevents materialization, propagates its error, and
# cleans the temporary hook state created for startup.
if sf_session_startup_create "$failed" "$SF_TEST_RUNTIME"; then
  fail 'failed session hook created a session'
fi
[[ $SF_SESSION_STARTUP_ERROR == *"hook failed with status 9: $hook: startup detail"* ]]
[[ ! -e $failed && -s $marker ]]
typeset state_dir=$(<"$marker")
[[ ! -e $state_dir ]]
[[ -z ${SHELLFISH_STATE_DIR-} ]]
