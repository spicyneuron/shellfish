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

# Policy cases consume captured files; subprocess coverage remains above and below.
functions -c sf_hooks_capture_one sf_hooks_capture_real
typeset -A capture_status=() capture_context=() capture_display=() capture_control=()
capture_result() {
  local name=$1
  script="$scripts/$name"
  capture_status[$script]=$2
  capture_context[$script]=${3-}
  capture_display[$script]=${4-}
  capture_control[$script]=${5-}
}
sf_hooks_capture_one() {
  local target=$1 directory=$3
  local context="$directory/current-context"
  local display="$directory/current-display"
  local control="$directory/current-control"
  print -rn -- "${capture_context[$target]-}" >"$context"
  print -rn -- "${capture_display[$target]-}" >"$display"
  print -rn -- "${capture_control[$target]-}" >"$control"
  reply=( "${capture_status[$target]}" "$context" "$display" "$control" )
}

# Each script retains its attribution and independently captured channels.
capture_result context_only 0 from-stdout
typeset context_only=$script
capture_result display_only 0 '' from-stderr
typeset display_only=$script
sf_hooks_dispatch "$empty" 64 0 0 "$context_only" "$display_only"
(( ${#SF_HOOK_SCRIPT_RESULTS} == 10 ))
[[ $SF_HOOK_SCRIPT_RESULTS[1] == "$context_only" && $SF_HOOK_SCRIPT_RESULTS[3] == from-stdout &&
   -z $SF_HOOK_SCRIPT_RESULTS[4] ]]
[[ $SF_HOOK_SCRIPT_RESULTS[6] == "$display_only" && -z $SF_HOOK_SCRIPT_RESULTS[8] &&
   $SF_HOOK_SCRIPT_RESULTS[9] == from-stderr ]]

# Status 10 skips sticky default behavior while later scripts continue in order.
capture_result skip 10 first
typeset skip=$script
capture_result later 0 second
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
capture_result control 11 before '' '{"action":"handoff","argv":["one","","line\\nbreak"]}'
typeset control=$script
capture_result forbidden 0 forbidden
typeset forbidden=$script
sf_hooks_dispatch "$empty" 64 1 0 "$control" "$forbidden"
(( ! reply[1] ))
[[ -z $REPLY && $reply[3] == "$control" ]]
[[ $reply[4] == '{"action":"handoff","argv":["one","","line\\nbreak"]}' ]]

capture_result halt 11 feedback
typeset halt=$script
sf_hooks_dispatch "$empty" 64 0 0 "$halt" "$forbidden"
(( ! reply[1] ))
[[ -z $REPLY && $reply[3] == "$halt" && -z $reply[4] ]]

# Structured control is accepted on any successful status when the hook allows
# it, and rejected when the caller disallows it.
capture_result status_zero 0 '' '' '{"action":"test"}'
typeset status_zero=$script
sf_hooks_dispatch "$empty" 64 1 0 "$status_zero"
[[ $reply[4] == '{"action":"test"}' ]]

if sf_hooks_dispatch "$empty" 64 0 0 "$control"; then
  fail 'control for an unsupported hook was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script returned unexpected control data: $control" ]]

# Invalid JSON is malformed and never reaches an adapter.
capture_result malformed 11 '' '' argument
typeset malformed=$script
if sf_hooks_dispatch "$empty" 64 1 0 "$malformed"; then
  fail 'malformed JSON control was accepted'
fi
[[ $SF_HOOK_ERROR == 'hook script returned malformed control data' && -z $REPLY && ${#reply} == 0 ]]

capture_result multiple 11 '' '' '{}{}'
typeset multiple=$script
if sf_hooks_dispatch "$empty" 64 1 0 "$multiple"; then
  fail 'multiple JSON control objects were accepted'
fi
[[ $SF_HOOK_ERROR == 'hook script returned malformed control data' ]]

# Unexpected exits discard all accumulated candidate output.
capture_result failed 9 failed detail
typeset failed=$script
if sf_hooks_dispatch "$empty" 64 0 0 "$later" "$failed"; then
  fail 'unexpected script status was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script failed with status 9: $failed: detail" ]]
[[ -z $REPLY && ${#reply} == 0 ]]
(( ${#SF_HOOK_SCRIPT_RESULTS} == 0 ))

# Each script receives its own combined output budget.
capture_result forty 0 "${(l:40::0:)""}"
typeset forty=$script
capture_result thirty 0 "${(l:30::0:)""}"
typeset thirty=$script
sf_hooks_dispatch "$empty" 64 0 0 "$forty" "$thirty"
(( ${#SF_HOOK_SCRIPT_RESULTS} == 10 ))

capture_result combined_overflow 0 "${(l:40::0:)""}" "${(l:25::0:)""}"
typeset combined_overflow=$script
if sf_hooks_dispatch "$empty" 64 0 0 "$combined_overflow"; then
  fail 'combined hook overflow was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script output exceeds capture limit: $combined_overflow" ]]

functions -c sf_hooks_capture_real sf_hooks_capture_one
unfunction sf_hooks_capture_real

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
