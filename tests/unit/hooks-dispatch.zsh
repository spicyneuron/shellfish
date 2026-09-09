#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"
typeset -g SF_HOOK_NAME=test_hook
typeset -gA SF_SESSION=(runtime '{"backend":{"environment":[],"env_file":""},"harness":{"tools":[]}}')

typeset input="$tmp/input" empty="$tmp/empty" original_directory=$PWD
print -rn -- '{"sample":"test"}' >"$input"
: >"$empty"

dispatch_hooks() {
  local input=$1 max_capture=$2 allow_control=$3 argument_count=$4 script
  shift 4
  local -a components
  for script in "$@"; do
    components+=( "$script" '' '[]' )
  done
  sf_hooks_dispatch "$input" "$max_capture" "$allow_control" "$argument_count" \
    "${components[@]}"
}

# An empty chain performs its default and produces no output.
dispatch_hooks "$empty" 64 0 0
(( reply[1] ))
[[ -z $REPLY && -z $reply[3] && -z $reply[4] ]]

# stdin is one complete document, and mixed output preserves bytes including a
# trailing newline and NUL.
make_script mixed 'cat; print -rn -- $'\''\0tail\n'\''; print -rn -u2 -- $'\''local\n'\''; exit 0'
typeset mixed=$script
dispatch_hooks "$input" 64 0 0 "$mixed"
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
dispatch_hooks "$empty" 64 0 0 "$context_only" "$display_only"
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
dispatch_hooks "$empty" 64 0 0 "$skip" "$later"
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
dispatch_hooks "$empty" 64 1 0 "$control" "$forbidden"
(( ! reply[1] ))
[[ -z $REPLY && $reply[3] == "$control" ]]
[[ $reply[4] == '{"action":"handoff","argv":["one","","line\\nbreak"]}' ]]

capture_result halt 11 feedback
typeset halt=$script
dispatch_hooks "$empty" 64 0 0 "$halt" "$forbidden"
(( ! reply[1] ))
[[ -z $REPLY && $reply[3] == "$halt" && -z $reply[4] ]]

# Structured control is accepted on any successful status when the hook allows
# it, and rejected when the caller disallows it.
capture_result status_zero 0 '' '' '{"action":"test"}'
typeset status_zero=$script
dispatch_hooks "$empty" 64 1 0 "$status_zero"
[[ $reply[4] == '{"action":"test"}' ]]

# Common state is staged in script and array order, then removed before
# hook-specific control is returned to the adapter.
capture_result state_first 0 '' '' \
  '{"state":[{"name":"first","value":1},{"name":"second","value":null}]}'
typeset state_first=$script
capture_result state_action 0 '' '' \
  '{"action":"test","state":[{"name":"third","value":{"ok":true}}]}'
typeset state_action=$script
dispatch_hooks "$empty" 512 1 0 "$state_first" "$state_action"
[[ -z $SF_HOOK_SCRIPT_RESULTS[5] &&
   $SF_HOOK_SCRIPT_RESULTS[10] == '{"action":"test"}' &&
   $reply[4] == '{"action":"test"}' ]]
[[ ${(pj:\n:)SF_HOOK_STATE_RECORDS} == $'{"type":"state","name":"first","value":1}\n{"type":"state","name":"second","value":null}\n{"type":"state","name":"third","value":{"ok":true}}' ]]

dispatch_hooks "$empty" 512 0 0 "$state_first"
[[ ${#SF_HOOK_STATE_RECORDS} == 2 && -z $reply[4] ]]

capture_result empty_control 0 '' '' '{}'
typeset empty_control=$script
if dispatch_hooks "$empty" 64 0 0 "$empty_control"; then
  fail 'empty control for an unsupported hook was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script returned unexpected control data: $empty_control" ]]

if dispatch_hooks "$empty" 64 0 0 "$control"; then
  fail 'control for an unsupported hook was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script returned unexpected control data: $control" ]]

# Invalid JSON is malformed and never reaches an adapter.
capture_result malformed 11 '' '' argument
typeset malformed=$script
if dispatch_hooks "$empty" 64 1 0 "$malformed"; then
  fail 'malformed JSON control was accepted'
fi
[[ $SF_HOOK_ERROR == 'hook script returned malformed control data' && -z $REPLY && ${#reply} == 0 ]]

capture_result multiple 11 '' '' '{}{}'
typeset multiple=$script
if dispatch_hooks "$empty" 64 1 0 "$multiple"; then
  fail 'multiple JSON control objects were accepted'
fi
[[ $SF_HOOK_ERROR == 'hook script returned malformed control data' ]]

capture_result invalid_state 0 '' '' '{"state":[{"name":"bad name","value":1}]}'
typeset invalid_state=$script
if dispatch_hooks "$empty" 512 1 0 "$state_first" "$invalid_state"; then
  fail 'invalid hook state was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script returned invalid state control: $invalid_state" &&
   ${#SF_HOOK_STATE_RECORDS} == 0 && ${#SF_HOOK_SCRIPT_RESULTS} == 0 ]]

# Unexpected exits discard all accumulated candidate output.
capture_result failed 9 failed detail
typeset failed=$script
if dispatch_hooks "$empty" 64 0 0 "$later" "$failed"; then
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
dispatch_hooks "$empty" 64 0 0 "$forty" "$thirty"
(( ${#SF_HOOK_SCRIPT_RESULTS} == 10 ))

capture_result combined_overflow 0 "${(l:40::0:)""}" "${(l:25::0:)""}"
typeset combined_overflow=$script
if dispatch_hooks "$empty" 64 0 0 "$combined_overflow"; then
  fail 'combined hook overflow was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script output exceeds capture limit: $combined_overflow" ]]

functions -c sf_hooks_capture_real sf_hooks_capture_one
unfunction sf_hooks_capture_real

# Prepared stdin and argv reach scripts without newline insertion or shell parsing.
make_script invocation 'print -rn -- "$#|$1|$2|$3|"; cat; print -rn -- "|$PWD|$SHELLFISH_SESSION|$SHELLFISH_MAX_CAPTURE_BYTES|$SHELLFISH_TURN_STATE|$SHELLFISH_MODEL|$0|${0:A:h}"'
typeset invocation=$script
typeset working="$tmp/working" session="$tmp/session.jsonl" state
mkdir "$working"
working=${working:A}
: >"$session"
print -rn -- $'first\nsecond\n' >"$input"
typeset -gA SF_SESSION=(model model-name cwd "$working" \
  runtime '{"backend":{"environment":[],"env_file":""},"harness":{"tools":[]}}')
typeset -g SHELLFISH_TURN_ID=1
sf_hooks_turn_state_create
state=$SHELLFISH_TURN_STATE
[[ $(stat -f %Lp "$state") == 700 ]]
print -n shared >"$state/marker"
sf_hooks_invoke "$session" "$working" "$input" 4096 0 3 stop '' $'line\nbreak' \
  "$invocation" '' '[]' || fail "$SF_HOOK_ERROR"
typeset expected="3|stop||"$'line\nbreak|first\nsecond\n'"|$working|${session:A}|4096|$state|model-name|$invocation|${invocation:A:h}"
assert_equal "$expected" "$SF_HOOK_SCRIPT_RESULTS[3]"
[[ $(cat "$state/marker") == shared ]]
[[ $PWD == $original_directory ]]
make_script hook_only 'print -rn -- "$#|$1|"; cat'
typeset hook_only=$script
print -rn -- $'first\nsecond' >"$input"
typeset -g SHELLFISH_TURN_ID=1
typeset -g +x SHELLFISH_TURN_ID
sf_hooks_invoke "$session" "$working" "$input" 512 0 1 stop "$hook_only" '' '[]'
[[ $SF_HOOK_SCRIPT_RESULTS[3] == $'1|stop|first\nsecond' ]]
[[ ${(t)SHELLFISH_TURN_ID} != *export* ]]
: >"$empty"
sf_hooks_invoke "$session" "$working" "$empty" 512 0 1 stop "$hook_only" '' '[]'
[[ $SF_HOOK_SCRIPT_RESULTS[3] == '1|stop|' ]]
sf_hooks_turn_state_cleanup
[[ -z $SHELLFISH_TURN_STATE && ! -e $state ]]
sf_hooks_turn_state_create
typeset next_state=$SHELLFISH_TURN_STATE
[[ $next_state != $state && -d $next_state ]]

# A hook receives its selected environment and not names selected by other components.
SF_SESSION[runtime]='{"backend":{"environment":["BACKEND_SETTING"],"env_file":""},"harness":{"tools":[{"manifest":{"environment":["HOOK_SETTING","TOOL_SETTING","SHELLFISH_SESSION"]}}]}}'
export BACKEND_SETTING=backend HOOK_SETTING=hook TOOL_SETTING=tool SHELLFISH_SESSION=external
make_script selected_environment 'print -rn -- "${BACKEND_SETTING-unset}|${HOOK_SETTING-unset}|${TOOL_SETTING-unset}|$SHELLFISH_SESSION"'
typeset selected_environment=$script
sf_hooks_invoke "$session" "$working" "$empty" 512 0 1 stop \
  "$selected_environment" '' '["HOOK_SETTING","SHELLFISH_SESSION"]' || fail "$SF_HOOK_ERROR"
assert_equal "unset|hook|unset|${session:A}" "$SF_HOOK_SCRIPT_RESULTS[3]"
unset BACKEND_SETTING HOOK_SETTING TOOL_SETTING SHELLFISH_SESSION

# Turn-only fixed context remains absent from session_start even when selected.
print -r -- 'SHELLFISH_TURN_ID=external' >"$tmp/component.env"
SF_SESSION[runtime]=$(jq -c --arg path "$tmp/component.env" '
  .backend.env_file=$path |
  .harness.tools[0].manifest.environment += ["SHELLFISH_TURN_ID"]
' <<<"$SF_SESSION[runtime]")
make_script no_turn 'print -rn -- "${SHELLFISH_TURN_ID-unset}"'
typeset no_turn=$script
sf_hooks_invoke "$session" "$working" "$empty" 512 0 1 session_start \
  "$no_turn" '' '["SHELLFISH_TURN_ID"]' || fail "$SF_HOOK_ERROR"
assert_equal unset "$SF_HOOK_SCRIPT_RESULTS[3]"
sf_hooks_turn_state_cleanup

assert_no_hook_captures
