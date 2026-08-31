#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source session/startup.zsh
sf_test_tmp startup
sf_test_runtime

typeset failed="$tmp/failed.jsonl" script="$tmp/failing-script" marker="$tmp/state-marker"
cat >"$script" <<'ZSH'
#!/usr/bin/env zsh
[[ $1 == session_start && -d $SHELLFISH_SESSION_STATE && -z ${SHELLFISH_TURN_STATE-} ]] || exit 2
print -r -- "$SHELLFISH_SESSION_STATE" >"$SF_TEST_STATE_MARKER"
print -u2 -r -- 'startup detail'
exit 9
ZSH
chmod +x "$script"
SF_TEST_RUNTIME=$(jq -c --arg script "$script" '.harness.session_start=[$script]' \
  <<<"$SF_TEST_RUNTIME")
export XDG_STATE_HOME="$tmp/state" SF_TEST_STATE_MARKER="$marker"

# A real hook script failure prevents materialization and propagates its error. Session
# state remains a disposable cache even when transcript creation fails.
if sf_session_startup_create "$failed" "$SF_TEST_RUNTIME"; then
  fail 'failed session_start script created a session'
fi
[[ $SF_SESSION_STARTUP_ERROR == *"hook script failed with status 9: $script: startup detail"* ]]
[[ ! -e $failed && -s $marker ]]
typeset state_dir=$(<"$marker")
[[ -d $state_dir && $state_dir == */sessions/failed ]]
[[ -z ${SHELLFISH_TURN_STATE-} ]]
