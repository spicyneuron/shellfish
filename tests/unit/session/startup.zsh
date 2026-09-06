#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source lib/session/startup.zsh
sf_test_tmp startup

# A fake entry point stands in for the create program.
typeset entry="$tmp/entry" invocation="$tmp/invocation"
cat >"$entry" <<'ZSH'
#!/usr/bin/env zsh
print -r -- "$*" >"$SF_TEST_INVOCATION"
[[ -z $SF_TEST_CREATE_FAILS ]] || { print -u2 -r -- 'shellfish: create failed'; exit 1; }
typeset target=$SF_TEST_CREATED
[[ $2 != --session-out ]] || target=$3
: >"$target"
print -r -- "$target"
ZSH
chmod +x "$entry"
typeset -g SF_ENTRY=$entry
export SF_TEST_INVOCATION="$invocation"

# Opening rejects runtime overrides against an existing session.
typeset existing="$tmp/existing.jsonl"
print -r -- '{}' >"$existing"
sf_session_select_path() { REPLY=$1; }
integer open_status=0
sf_session_open "$existing" 1 || open_status=$?
(( open_status == 2 ))
[[ $SF_SESSION_STARTUP_ERROR == 'options that configure a new session cannot be used with an existing one' ]]

# An existing session reports only its path, mode, and current presentation. Its
# frozen runtime stays in the transcript, and nothing is created.
rm -f -- "$invocation"
sf_session_open "$existing" 0
assert_equal "$existing" "$SF_SESSION_OPEN[path]"
assert_equal resume "$SF_SESSION_OPEN[mode]"
[[ ! -e $invocation ]]

# A requested session must already exist. Nothing is created in its place.
rm -f -- "$invocation"
typeset fresh="$tmp/fresh.jsonl"
open_status=0
sf_session_open "$fresh" 0 || open_status=$?
(( open_status == 1 ))
[[ $SF_SESSION_STARTUP_ERROR == "no session at $fresh; use --session-out to create one" ]]
[[ ! -e $invocation && ! -e $fresh ]]

# Without a requested session, create selects the destination and reports it.
# Options the client did not consume are forwarded unparsed.
export SF_TEST_CREATED="$tmp/selected.jsonl"
sf_session_open '' 0 --profile work --sandbox-auto
assert_equal "$SF_TEST_CREATED" "$SF_SESSION_OPEN[path]"
assert_equal startup "$SF_SESSION_OPEN[mode]"
assert_equal 'create --profile work --sandbox-auto' "$(<"$invocation")"

# Create owns the destination and the settings source; both ride through.
sf_session_open '' 0 --session-out "$fresh" --session-from "$existing"
assert_equal "$fresh" "$SF_SESSION_OPEN[path]"
assert_equal "create --session-out $fresh --session-from $existing" "$(<"$invocation")"

# Create reports its own failures, so opening adds no second message.
SF_TEST_CREATE_FAILS=1 sf_session_open '' 0 && fail 'create failure was ignored'
[[ -z $SF_SESSION_STARTUP_ERROR ]]
