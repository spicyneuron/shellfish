#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"
typeset -g SF_HOOK_NAME=test_hook

typeset input="$tmp/input" empty="$tmp/empty" original_directory=$PWD
print -rn -- '{"sample":"test"}' >"$input"
: >"$empty"

# An empty chain performs its default and produces no output.
sf_hooks_dispatch "$empty" 64 0 0
(( reply[1] ))
[[ -z $REPLY && -z $reply[3] && -z $reply[4] ]]

# stdin is one complete document, and mixed output preserves bytes including a
# trailing newline and NUL.
make_script mixed 'cat; print -rn -- $'\''\0tail\n'\''; print -rn -u2 -- $'\''local\n'\''; exit 0'
typeset mixed=$script
sf_hooks_dispatch "$input" 64 0 0 "$mixed"
[[ -z $REPLY ]]
(( ${#SF_HOOK_SCRIPT_RESULTS} == 5 ))
[[ $SF_HOOK_SCRIPT_RESULTS[1] == "$mixed" && $SF_HOOK_SCRIPT_RESULTS[2] == 0 ]]
[[ $SF_HOOK_SCRIPT_RESULTS[3] == $'{"sample":"test"}\0tail\n' ]]
[[ $SF_HOOK_SCRIPT_RESULTS[4] == $'local\n' && -z $SF_HOOK_SCRIPT_RESULTS[5] ]]
(( reply[1] ))

# Each script retains its attribution and independently captured channels.
make_script context_only 'print -n from-stdout; exit 0'
typeset context_only=$script
make_script display_only 'print -rn -u2 -- from-stderr; exit 0'
typeset display_only=$script
sf_hooks_dispatch "$empty" 64 0 0 "$context_only" "$display_only"
(( ${#SF_HOOK_SCRIPT_RESULTS} == 10 ))
[[ $SF_HOOK_SCRIPT_RESULTS[1] == "$context_only" && $SF_HOOK_SCRIPT_RESULTS[3] == from-stdout &&
   -z $SF_HOOK_SCRIPT_RESULTS[4] ]]
[[ $SF_HOOK_SCRIPT_RESULTS[6] == "$display_only" && -z $SF_HOOK_SCRIPT_RESULTS[8] &&
   $SF_HOOK_SCRIPT_RESULTS[9] == from-stderr ]]

# Status 10 skips sticky default behavior while later scripts continue in order.
make_script skip 'print -n first; exit 10'
typeset skip=$script
make_script later 'print -n second; exit 0'
typeset later=$script
sf_hooks_dispatch "$empty" 64 0 0 "$skip" "$later"
(( ! reply[1] ))
[[ -z $REPLY && $reply[3] == "$skip" ]]
(( ${#SF_HOOK_SCRIPT_RESULTS} == 10 ))
[[ $SF_HOOK_SCRIPT_RESULTS[1] == "$skip" && $SF_HOOK_SCRIPT_RESULTS[2] == 10 &&
   $SF_HOOK_SCRIPT_RESULTS[3] == first ]]
[[ $SF_HOOK_SCRIPT_RESULTS[6] == "$later" && $SF_HOOK_SCRIPT_RESULTS[7] == 0 &&
   $SF_HOOK_SCRIPT_RESULTS[8] == second ]]

# Status 11 stops the chain and preserves structured JSON control.
make_script control 'print -n before; print -rn -u3 -- '\''{"action":"handoff","argv":["one","","line\\nbreak"]}'\''; exit 11'
typeset control=$script
make_script forbidden 'print -n forbidden; exit 0'
typeset forbidden=$script
sf_hooks_dispatch "$empty" 64 1 0 "$control" "$forbidden"
(( ! reply[1] ))
[[ -z $REPLY && $reply[3] == "$control" ]]
[[ $reply[4] == '{"action":"handoff","argv":["one","","line\\nbreak"]}' ]]

make_script halt 'print -n feedback; exit 11'
typeset halt=$script
sf_hooks_dispatch "$empty" 64 0 0 "$halt" "$forbidden"
(( ! reply[1] ))
[[ -z $REPLY && $reply[3] == "$halt" && -z $reply[4] ]]

# Structured control is accepted on any successful status when the hook allows
# it, and rejected when the caller disallows it.
make_script status_zero 'print -rn -u3 -- '\''{"action":"test"}'\''; exit 0'
typeset status_zero=$script
sf_hooks_dispatch "$empty" 64 1 0 "$status_zero"
[[ $reply[4] == '{"action":"test"}' ]]

if sf_hooks_dispatch "$empty" 64 0 0 "$control"; then
  fail 'control for an unsupported hook was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script returned unexpected control data: $control" ]]

# Invalid JSON is malformed and never reaches an adapter.
make_script malformed 'print -rn -u3 -- argument; exit 11'
typeset malformed=$script
if sf_hooks_dispatch "$empty" 64 1 0 "$malformed"; then
  fail 'malformed JSON control was accepted'
fi
[[ $SF_HOOK_ERROR == 'hook script returned malformed control data' && -z $REPLY && ${#reply} == 0 ]]

make_script multiple 'print -rn -u3 -- '\''{}{}'\''; exit 11'
typeset multiple=$script
if sf_hooks_dispatch "$empty" 64 1 0 "$multiple"; then
  fail 'multiple JSON control objects were accepted'
fi
[[ $SF_HOOK_ERROR == 'hook script returned malformed control data' ]]

# Unexpected exits discard all accumulated candidate output.
make_script failed 'print -n failed; print -n -u2 detail; exit 9'
typeset failed=$script
if sf_hooks_dispatch "$empty" 64 0 0 "$later" "$failed"; then
  fail 'unexpected script status was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script failed with status 9: $failed: detail" ]]
[[ -z $REPLY && ${#reply} == 0 ]]
(( ${#SF_HOOK_SCRIPT_RESULTS} == 0 ))

# Each script receives its own combined output budget.
make_script forty 'printf %040d 0; exit 0'
typeset forty=$script
make_script thirty 'printf %030d 0; exit 0'
typeset thirty=$script
sf_hooks_dispatch "$empty" 64 0 0 "$forty" "$thirty"
(( ${#SF_HOOK_SCRIPT_RESULTS} == 10 ))

make_script combined_overflow 'printf %040d 0; printf %025d 0 >&2; exit 0'
typeset combined_overflow=$script
if sf_hooks_dispatch "$empty" 64 0 0 "$combined_overflow"; then
  fail 'combined hook overflow was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script output exceeds capture limit: $combined_overflow" ]]

# The system hook interleaves static files, .zsh producers, and other executables.
typeset static="$tmp/static.md" zsh_component="$tmp/dynamic.zsh"
print -rn -- 'static' >"$static"
cat >"$zsh_component" <<'ZSH'
[[ $# == 1 && $1 == system ]] || exit 2
print -rn -- dynamic
ZSH
chmod -x "$zsh_component"
make_script executable '[[ $# == 1 && $1 == system ]] || exit 2; print -rn -- executable'
typeset executable=$script
SF_HOOK_NAME=system
sf_hooks_dispatch "$empty" 64 0 1 system "$static" "$zsh_component" "$executable"
(( ${#SF_HOOK_SCRIPT_RESULTS} == 15 ))
[[ $SF_HOOK_SCRIPT_RESULTS[3] == static && $SF_HOOK_SCRIPT_RESULTS[8] == dynamic &&
  $SF_HOOK_SCRIPT_RESULTS[13] == executable ]]
SF_HOOK_NAME=test_hook

# Prepared stdin and argv reach scripts without newline insertion or shell parsing.
make_script invocation 'print -rn -- "$#|$1|$2|$3|"; cat; print -rn -- "|$PWD|$SHELLFISH_SESSION|$SHELLFISH_CAPTURE_LIMIT|$SHELLFISH_TURN_STATE|$SHELLFISH_SESSION_STATE|$SHELLFISH_SESSION_ID|$SHELLFISH_MODEL|$PROJECT_DIR|$HOOK_SCRIPT_ROOT"'
typeset invocation=$script
typeset working="$tmp/working" session="$tmp/session.jsonl" state
mkdir "$working"
working=${working:A}
: >"$session"
print -rn -- $'first\nsecond\n' >"$input"
typeset -gA SF_SESSION=(id session-id model model-name cwd "$working")
typeset -g SHELLFISH_TURN_ID=1
sf_hooks_turn_state_create
state=$SHELLFISH_TURN_STATE
[[ $(stat -f %Lp "$state") == 700 ]]
print -n shared >"$state/marker"
sf_hooks_invoke "$session" "$working" "$input" 1024 0 3 stop '' $'line\nbreak' "$invocation"
typeset expected="3|stop||"$'line\nbreak|first\nsecond\n'"|$working|${session:A}|1024|$state|$SHELLFISH_SESSION_STATE|session-id|model-name|$working|${invocation:h}"
assert_equal "$expected" "$SF_HOOK_SCRIPT_RESULTS[3]"
assert_equal 700 "$(stat -f %Lp "$SHELLFISH_SESSION_STATE")"
[[ $(cat "$state/marker") == shared ]]
[[ $PWD == $original_directory ]]
make_script hook_only 'print -rn -- "$#|$1|"; cat'
typeset hook_only=$script
print -rn -- $'first\nsecond' >"$input"
typeset -g SHELLFISH_TURN_ID=1
typeset -g +x SHELLFISH_TURN_ID
sf_hooks_invoke "$session" "$working" "$input" 512 0 1 stop "$hook_only"
[[ $SF_HOOK_SCRIPT_RESULTS[3] == $'1|stop|first\nsecond' ]]
[[ ${(t)SHELLFISH_TURN_ID} != *export* ]]
: >"$empty"
sf_hooks_invoke "$session" "$working" "$empty" 512 0 1 stop "$hook_only"
[[ $SF_HOOK_SCRIPT_RESULTS[3] == '1|stop|' ]]
typeset session_state=$SHELLFISH_SESSION_STATE
print -n persistent >"$session_state/marker"
sf_hooks_turn_state_cleanup
[[ -z $SHELLFISH_TURN_STATE && ! -e $state ]]
SHELLFISH_SESSION_STATE=''
sf_hooks_turn_state_create
typeset next_state=$SHELLFISH_TURN_STATE
[[ $SHELLFISH_SESSION_STATE == $session_state && $(<$session_state/marker) == persistent ]]
[[ $next_state != $state && -d $next_state ]]
sf_hooks_turn_state_cleanup

assert_no_hook_captures
