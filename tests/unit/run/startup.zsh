#!/usr/bin/env zsh

source "${0:A:h:h:h}/_helpers.zsh"
sf_test_source libexec/run/startup.zsh
sf_test_tmp startup

# Report failures the way run does.
typeset -g SF_TEST_DIED=''
sf_die() { SF_TEST_DIED=$1; return 1; }

# Stub the create entry point.
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

# Existing sessions reject runtime overrides.
typeset existing="$tmp/existing.jsonl"
print -r -- '{}' >"$existing"
sf_session_select_path() { REPLY=$1; }
integer open_status=0
sf_run_open_session "$existing" 1 || open_status=$?
(( open_status == 2 ))
assert_equal 'options that configure a new session cannot be used with an existing one' \
  "$SF_TEST_DIED"

# Existing sessions resume without creation.
rm -f -- "$invocation"
sf_run_open_session "$existing" 0
assert_equal "$existing" "$REPLY"
[[ ! -e $invocation ]]

# Missing requested sessions fail.
rm -f -- "$invocation"
typeset fresh="$tmp/fresh.jsonl"
open_status=0
sf_run_open_session "$fresh" 0 || open_status=$?
(( open_status == 1 ))
assert_equal "no session at $fresh; use --session-out to create one" "$SF_TEST_DIED"
[[ ! -e $invocation && ! -e $fresh ]]

# Unconsumed options pass through to create.
export SF_TEST_CREATED="$tmp/selected.jsonl"
sf_run_open_session '' 0 --profile work --sandbox-auto
assert_equal "$SF_TEST_CREATED" "$REPLY"
assert_equal 'create --profile work --sandbox-auto' "$(<"$invocation")"

# Create receives destination and source.
sf_run_open_session '' 0 --session-out "$fresh" --session-from "$existing"
assert_equal "$fresh" "$REPLY"
assert_equal "create --session-out $fresh --session-from $existing" "$(<"$invocation")"

# Create failures pass through unchanged.
SF_TEST_DIED=''
SF_TEST_CREATE_FAILS=1 sf_run_open_session '' 0 && fail 'create failure was ignored'
[[ -z $SF_TEST_DIED ]]
