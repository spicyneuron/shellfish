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
[[ $2 != --path ]] || target=$3
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
sf_session_open "$existing" 1 0 '' || open_status=$?
(( open_status == 2 ))
[[ $SF_SESSION_STARTUP_ERROR == 'runtime overrides cannot be used with an existing session' ]]

# An existing session reports only its path, mode, and current presentation. Its
# frozen runtime stays in the transcript, and nothing is created.
rm -f -- "$invocation"
sf_session_open "$existing" 0 0 ''
assert_equal "$existing" "$SF_SESSION_OPEN[path]"
assert_equal resume "$SF_SESSION_OPEN[mode]"
[[ ! -e $invocation ]]

# A requested path that holds no session is created there, and the runtime
# options the client did not consume are forwarded unparsed.
typeset fresh="$tmp/fresh.jsonl"
sf_session_open "$fresh" 1 0 '' --profile work --sandbox-auto
assert_equal "$fresh" "$SF_SESSION_OPEN[path]"
assert_equal startup "$SF_SESSION_OPEN[mode]"
assert_equal "create --path $fresh --profile work --sandbox-auto" "$(<"$invocation")"
[[ -e $fresh ]]

# Without a requested path, create selects the destination and reports it.
export SF_TEST_CREATED="$tmp/selected.jsonl"
sf_session_open '' 0 0 ''
assert_equal "$SF_TEST_CREATED" "$SF_SESSION_OPEN[path]"
assert_equal startup "$SF_SESSION_OPEN[mode]"
assert_equal 'create' "$(<"$invocation")"

# A source session is forwarded as the session the runtime comes from.
sf_session_open '' 0 0 "$existing"
assert_equal "create --session $existing" "$(<"$invocation")"

# Create reports its own failures, so opening adds no second message.
SF_TEST_CREATE_FAILS=1 sf_session_open '' 0 0 '' && fail 'create failure was ignored'
[[ -z $SF_SESSION_STARTUP_ERROR ]]
