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

# A fake entry point stands in for the create program.
typeset entry="$tmp/entry" invocation="$tmp/invocation"
cat >"$entry" <<'ZSH'
#!/usr/bin/env zsh
print -r -- "$*" >"$SF_TEST_INVOCATION"
[[ -z $SF_TEST_CREATE_FAILS ]] || { print -u2 -r -- 'shellfish: create failed'; exit 1; }
typeset target=$SF_TEST_CREATED
[[ $2 != --path ]] || target=$3
: >"$target"
print -r -- "$target"
ZSH
chmod +x "$entry"
typeset -g SF_ENTRY=$entry
export SF_TEST_INVOCATION="$invocation"
sf_runtime_restore_presentation() { SF_PRESENTATION='{"source":"config"}'; }

# Opening rejects runtime overrides against an existing session.
typeset existing="$tmp/existing.jsonl"
print -r -- '{}' >"$existing"
sf_session_select_path() { REPLY=$1; }
integer open_status=0
sf_session_open "$existing" '' 1 0 '' || open_status=$?
(( open_status == 2 ))
[[ $SF_SESSION_STARTUP_ERROR == 'runtime overrides cannot be used with an existing session' ]]

# An existing session reports only its path, mode, and current presentation. Its
# frozen runtime stays in the transcript, and nothing is created.
rm -f -- "$invocation"
sf_session_open "$existing" '' 0 0 ''
assert_equal "$existing" "$SF_SESSION_OPEN[path]"
assert_equal resume "$SF_SESSION_OPEN[mode]"
assert_equal '{"source":"config"}' "$SF_SESSION_OPEN[presentation]"
[[ ! -e $invocation ]]

# A requested path that holds no session is created there, and the runtime
# options the client did not consume are forwarded unparsed.
typeset fresh="$tmp/fresh.jsonl"
sf_session_open "$fresh" '' 1 0 '' --profile work --sandbox-auto
assert_equal "$fresh" "$SF_SESSION_OPEN[path]"
assert_equal startup "$SF_SESSION_OPEN[mode]"
assert_equal '{"source":"config"}' "$SF_SESSION_OPEN[presentation]"
assert_equal "create --path $fresh --profile work --sandbox-auto" "$(<"$invocation")"
[[ -e $fresh ]]

# Without a requested path, create selects the destination and reports it.
export SF_TEST_CREATED="$tmp/selected.jsonl"
sf_session_open '' '' 0 0 ''
assert_equal "$SF_TEST_CREATED" "$SF_SESSION_OPEN[path]"
assert_equal startup "$SF_SESSION_OPEN[mode]"
assert_equal 'create' "$(<"$invocation")"

# A source session is forwarded as the session the runtime comes from.
sf_session_open '' '' 0 0 "$existing"
assert_equal "create --session $existing" "$(<"$invocation")"

# Create reports its own failures, so opening adds no second message.
SF_TEST_CREATE_FAILS=1 sf_session_open '' '' 0 0 '' && fail 'create failure was ignored'
[[ -z $SF_SESSION_STARTUP_ERROR ]]
