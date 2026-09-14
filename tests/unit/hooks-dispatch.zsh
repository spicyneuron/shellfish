#!/usr/bin/env zsh

source "${0:A:h}/_hooks.zsh"
typeset -g SF_HOOK_NAME=test_hook
typeset -gA SF_SESSION=(runtime '{"backend":{"environment":[],"env_file":""},"harness":{"tools":[]}}')

typeset input="$tmp/input" empty="$tmp/empty" original_directory=$PWD
typeset -a component_results=()
typeset -g SF_HOOK_SESSION=''
typeset -g SF_HOOK_STDOUT_POLICY=ignore
typeset -g SF_HOOK_SKIP_POLICY=allow
print -rn -- '{"sample":"test"}' >"$input"
: >"$empty"

capture_component() {
  component_results+=( "$1" "$2" "$3" "$4" )
}
typeset -g SF_HOOK_COMPONENT_VALIDATOR=capture_component

dispatch_hooks() {
  local input=$1 max_capture=$2 allow_control=$3 argument_count=$4 script
  shift 4
  local -a components
  component_results=()
  for script in "$@"; do
    components+=( "$script" '' '' '' )
  done
  sf_hooks_dispatch "$input" "$max_capture" "$allow_control" "$argument_count" \
    "${components[@]}"
}

# Run empty chains silently.
dispatch_hooks "$empty" 64 0 0
(( reply[1] ))
[[ -z $REPLY && -z $reply[3] && -z $reply[4] ]]

# Captures preserve exact stdin, trailing newlines, and NULs.
make_script mixed 'cat; print -rn -- $'\''\0tail\n'\''; print -rn -u2 -- $'\''local\n'\''; exit 0'
typeset mixed=$script
dispatch_hooks "$input" 64 0 0 "$mixed"
[[ -z $REPLY ]]
(( ${#component_results} == 4 ))
[[ $component_results[1] == "$mixed" && $component_results[2] == 0 ]]
[[ $component_results[3] == $'{"sample":"test"}\0tail\n' ]]
[[ -z $component_results[4] ]]
(( reply[1] ))

# Capture hook policy cases.
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

# Preserve per-script attribution.
capture_result context_only 0 from-stdout
typeset context_only=$script
capture_result display_only 0 '' from-stderr
typeset display_only=$script
dispatch_hooks "$empty" 64 0 0 "$context_only" "$display_only"
(( ${#component_results} == 8 ))
[[ $component_results[1] == "$context_only" && $component_results[3] == from-stdout ]]
[[ $component_results[5] == "$display_only" && -z $component_results[7] ]]

# Clear unmatched activity labels.
capture_result displayed_empty 0
typeset displayed_empty=$script activity_events
SF_HOOK_JSONL=1
activity_events=$(sf_hooks_dispatch "$empty" 64 0 0 \
  "$displayed_empty" 'Working' '' '')
SF_HOOK_JSONL=0
print -r -- "$activity_events" | jq -eRn '
  [inputs | fromjson] == [
    {type:"_hook_activity",hook:"test_hook",script:"displayed_empty",text:"Working"},
    {type:"_hook_activity",text:""}
  ]
' >/dev/null

# Match status 0 selects; status 1 skips.
capture_result selector 1
typeset selector=$script
component_results=()
sf_hooks_dispatch "$empty" 64 0 0 "$context_only" '' "$selector" ''
(( ${#component_results} == 0 ))
capture_status[$selector]=0
component_results=()
sf_hooks_dispatch "$empty" 64 0 0 "$context_only" '' "$selector" ''
[[ $component_results[1] == "$context_only" ]]
capture_display[$selector]=unexpected
component_results=()
if sf_hooks_dispatch "$empty" 64 0 0 "$context_only" '' "$selector" ''; then
  fail 'a match command that wrote output was accepted'
fi
[[ $SF_HOOK_ERROR == "hook match command wrote output: $selector" ]]
capture_display[$selector]=''
capture_status[$selector]=2
component_results=()
if sf_hooks_dispatch "$empty" 64 0 0 "$context_only" '' "$selector" ''; then
  fail 'a failed match command was accepted'
fi
[[ $SF_HOOK_ERROR == "hook match command failed with status 2: $selector" ]]

# Status 10 clears the default and continues.
capture_result skip 10 first
typeset skip=$script
capture_result later 0 second
typeset later=$script
dispatch_hooks "$empty" 64 0 0 "$skip" "$later"
(( ! reply[1] ))
[[ -z $REPLY && $reply[3] == "$skip" ]]
(( ${#component_results} == 8 ))
[[ $component_results[1] == "$skip" && $component_results[2] == 10 &&
   $component_results[3] == first ]]
[[ $component_results[5] == "$later" && $component_results[6] == 0 &&
   $component_results[7] == second ]]

# Status 11 halts with control.
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

# Common state is stripped before adapter validation.
capture_result state_first 0 '' '' \
  '{"state":[{"name":"first","value":1},{"name":"second","value":null}]}'
typeset state_first=$script
capture_result state_action 0 '' '' \
  '{"action":"test","state":[{"name":"third","value":{"ok":true}}]}'
typeset state_action=$script
dispatch_hooks "$empty" 512 1 0 "$state_first" "$state_action"
[[ -z $component_results[4] &&
   $component_results[8] == '{"action":"test"}' &&
   $reply[4] == '{"action":"test"}' ]]

dispatch_hooks "$empty" 512 0 0 "$state_first"
[[ -z $reply[4] ]]

if dispatch_hooks "$empty" 64 0 0 "$control"; then
  fail 'control for an unsupported hook was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script returned unexpected control data: $control" ]]

# Reject malformed control JSON.
capture_result malformed 11 '' '' argument
typeset malformed=$script
if dispatch_hooks "$empty" 64 1 0 "$malformed"; then
  fail 'malformed JSON control was accepted'
fi
[[ $SF_HOOK_ERROR == 'hook script returned malformed control data' && -z $REPLY && ${#reply} == 0 ]]

capture_result invalid_state 0 '' '' '{"state":[{"name":"bad name","value":1}]}'
typeset invalid_state=$script
if dispatch_hooks "$empty" 512 1 0 "$state_first" "$invalid_state"; then
  fail 'invalid hook state was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script returned invalid state control: $invalid_state" &&
   ${#component_results} == 4 ]]

# Preserve results before later failures.
capture_result failed 9 failed detail
typeset failed=$script
if dispatch_hooks "$empty" 64 0 0 "$later" "$failed"; then
  fail 'unexpected script status was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script failed with status 9: $failed: detail" ]]
[[ -z $REPLY && ${#reply} == 0 ]]
(( ${#component_results} == 4 ))

# Capture budgets apply per script across all channels.
capture_result forty 0 "${(l:40::0:)""}"
typeset forty=$script
capture_result thirty 0 "${(l:30::0:)""}"
typeset thirty=$script
dispatch_hooks "$empty" 64 0 0 "$forty" "$thirty"
(( ${#component_results} == 8 ))

capture_result combined_overflow 0 "${(l:40::0:)""}" "${(l:25::0:)""}"
typeset combined_overflow=$script
if dispatch_hooks "$empty" 64 0 0 "$combined_overflow"; then
  fail 'combined hook overflow was accepted'
fi
[[ $SF_HOOK_ERROR == "hook script output exceeds capture limit: $combined_overflow" ]]

functions -c sf_hooks_capture_real sf_hooks_capture_one
unfunction sf_hooks_capture_real

# Invocation preserves stdin and argv without shell parsing.
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
component_results=()
sf_hooks_invoke "$session" "$working" "$input" 4096 0 3 stop '' $'line\nbreak' \
  "$invocation" '' '' '' || fail "$SF_HOOK_ERROR"
typeset expected="3|stop||"$'line\nbreak|first\nsecond\n'"|$working|${session:A}|4096|$state|model-name|$invocation|${invocation:A:h}"
assert_equal "$expected" "$component_results[3]"
[[ $(cat "$state/marker") == shared ]]
[[ $PWD == $original_directory ]]
make_script hook_only 'print -rn -- "$#|$1|"; cat'
typeset hook_only=$script
print -rn -- $'first\nsecond' >"$input"
typeset -g SHELLFISH_TURN_ID=1
typeset -g +x SHELLFISH_TURN_ID
component_results=()
sf_hooks_invoke "$session" "$working" "$input" 512 0 1 stop "$hook_only" '' '' ''
[[ $component_results[3] == $'1|stop|first\nsecond' ]]
[[ ${(t)SHELLFISH_TURN_ID} != *export* ]]
[[ ${(t)SHELLFISH_TURN_STATE} != *export* ]]
: >"$empty"
component_results=()
sf_hooks_invoke "$session" "$working" "$empty" 512 0 1 stop "$hook_only" '' '' ''
[[ $component_results[3] == '1|stop|' ]]
sf_hooks_turn_state_cleanup
[[ -z $SHELLFISH_TURN_STATE && ! -e $state ]]
sf_hooks_turn_state_create
typeset next_state=$SHELLFISH_TURN_STATE
[[ $next_state != $state && -d $next_state ]]
[[ ${(t)SHELLFISH_TURN_STATE} != *export* ]]

# Hooks inherit exported values, import selected values, and receive authoritative context.
SF_SESSION[runtime]='{"backend":{"environment":["BACKEND_SETTING"],"env_file":""},"harness":{"tools":[{"manifest":{"environment":["HOOK_SETTING","TOOL_SETTING","SHELLFISH_SESSION"]}}]}}'
export BACKEND_SETTING=backend HOOK_SETTING=hook TOOL_SETTING=tool SHELLFISH_SESSION=external
make_script inherited_environment 'print -rn -- "${BACKEND_SETTING-unset}|${HOOK_SETTING-unset}|${TOOL_SETTING-unset}|$SHELLFISH_SESSION"'
typeset inherited_environment=$script
component_results=()
sf_hooks_invoke "$session" "$working" "$empty" 512 0 1 stop \
  "$inherited_environment" '' '' 'HOOK_SETTING SHELLFISH_SESSION' || fail "$SF_HOOK_ERROR"
assert_equal "backend|hook|tool|${session:A}" "$component_results[3]"
unset BACKEND_SETTING HOOK_SETTING TOOL_SETTING SHELLFISH_SESSION

# session_start cannot import turn-only context.
print -r -- 'SHELLFISH_TURN_ID=external' >"$tmp/component.env"
SF_SESSION[runtime]=$(jq -c --arg path "$tmp/component.env" '
  .backend.env_file=$path |
  .harness.tools[0].manifest.environment += ["SHELLFISH_TURN_ID"]
' <<<"$SF_SESSION[runtime]")
make_script no_turn 'print -rn -- "${SHELLFISH_TURN_ID-unset}"'
typeset no_turn=$script
component_results=()
sf_hooks_invoke "$session" "$working" "$empty" 512 0 1 session_start \
  "$no_turn" '' '' 'SHELLFISH_TURN_ID' || fail "$SF_HOOK_ERROR"
assert_equal unset "$component_results[3]"
sf_hooks_turn_state_cleanup

# Cleanup only removes turn state created by this process.
typeset inherited_state="$tmp/inherited-turn-state"
mkdir "$inherited_state"
SHELLFISH_TURN_STATE=$inherited_state
sf_hooks_turn_state_cleanup
[[ -z $SHELLFISH_TURN_STATE && -d $inherited_state ]]

assert_no_hook_captures
