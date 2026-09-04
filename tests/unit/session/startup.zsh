#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/startup.zsh
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

# System components concatenate into one ordered record before session_start context.
typeset first="$tmp/first.md" second="$tmp/second.md" joined="$tmp/joined.jsonl"
printf 'first prompt\n\n\n' >"$first"
printf 'second prompt\n' >"$second"
typeset joined_runtime=$(jq -c --arg first "${first:A}" --arg second "${second:A}" '
  .profile.system=[$first,$second] | .harness.session_start=[]
' <<<"$SF_TEST_RUNTIME")
sf_session_startup_create "$joined" "$joined_runtime"
jq -se '
  length == 2 and
  .[1] == {type:"system",content:"first prompt\n\nsecond prompt"}
' "$joined" >/dev/null

# An unreadable component fails without creating a transcript.
typeset missing="$tmp/missing.jsonl"
typeset missing_runtime=$(jq -c --arg path "$tmp/absent.md" '.profile.system=[$path]' \
  <<<"$joined_runtime")
if sf_session_startup_create "$missing" "$missing_runtime"; then
  fail 'missing system component created a session'
fi
[[ $SF_SESSION_STARTUP_ERROR == "cannot read system component: $tmp/absent.md" ]]
[[ ! -e $missing ]]
