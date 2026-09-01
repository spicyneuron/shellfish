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

# The system hook materializes one ordered record before session_start context.
typeset static="$tmp/system.md" dynamic="$tmp/system.zsh" mixed="$tmp/mixed.jsonl"
typeset display="$tmp/system-display"
print -r -- 'static prompt' >"$static"
cat >"$dynamic" <<'ZSH'
[[ $# == 1 && $1 == system && ! -s /dev/stdin ]] || exit 2
[[ $PWD == "$PROJECT_DIR" && $HOOK_SCRIPT_ROOT == ${0:A:h} ]] || exit 3
[[ -n $SHELLFISH_SESSION_ID && -d $SHELLFISH_SESSION_STATE ]] || exit 4
[[ -z ${SHELLFISH_TURN_ID-} && -z ${SHELLFISH_API_KEY-} && -z ${CUSTOM_API_KEY-} ]] || exit 5
print -r -- 'dynamic prompt'
print -u2 -n -- 'system detail'
ZSH
chmod -x "$dynamic"
typeset mixed_runtime=$(jq -c --arg static "${static:A}" --arg dynamic "${dynamic:A}" '
  .harness.system=[$static,$dynamic] | .harness.session_start=[] |
  .backend.api_key_env="CUSTOM_API_KEY"
' <<<"$SF_TEST_RUNTIME")
CUSTOM_API_KEY=secret sf_session_startup_create "$mixed" "$mixed_runtime" 2>"$display"
[[ $(<"$display") == 'system detail' ]]
jq -se '
  length == 2 and
  .[1] == {type:"system",content:"static prompt\n\ndynamic prompt"}
' "$mixed" >/dev/null

# Unsupported system hook statuses fail without creating a transcript.
typeset skip="$tmp/skip.zsh" skipped="$tmp/skipped.jsonl"
print -r -- 'exit 10' >"$skip"
typeset skip_runtime=$(jq -c --arg skip "${skip:A}" '.harness.system=[$skip]' <<<"$mixed_runtime")
if sf_session_startup_create "$skipped" "$skip_runtime"; then
  fail 'skipped system hook created a session'
fi
[[ $SF_SESSION_STARTUP_ERROR == 'system hook script returned unsupported skip status' ]]
[[ ! -e $skipped ]]
