emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_jq] )) || source "$SF_ROOT/lib/jq.zsh"
(( $+functions[sf_scratch_category] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_HOOK_ERROR=''
typeset -g SF_HOOK_JSONL=0
typeset -g SF_HOOK_COMPONENT_VALIDATOR=''
typeset -g SHELLFISH_TURN_STATE=${SHELLFISH_TURN_STATE-}
typeset -g SHELLFISH_TURN_ID=${SHELLFISH_TURN_ID-}
typeset -g SF_HOOK_NAME=''
typeset -gi SF_HOOK_ID=0
# A tool-lifecycle hook contributes to the owning call instead of settling.
typeset -gi SF_HOOK_COLLECT=0
typeset -ga SF_HOOK_CONTEXTS=()
typeset -g SF_HOOK_TURN_STATE_TEMP=''

zshexit() {
  [[ -z $SF_HOOK_TURN_STATE_TEMP ]] || rm -rf -- "$SF_HOOK_TURN_STATE_TEMP" 2>/dev/null || true
}

sf_hooks_reset() {
  SF_HOOK_ERROR=''
  REPLY=''
  reply=()
}

sf_hooks_fail() {
  local error=$1
  sf_hooks_reset
  SF_HOOK_ERROR=$error
  return 1
}

sf_hooks_activity() {
  local hook=$1 id=$2 name=$3 input=$4 executable=$5 rendered=$6
  (( SF_HOOK_JSONL )) || return 0
  jq -cn --arg hook "$hook" --arg id "$id" --arg name "$name" \
    --argjson input "$input" --arg executable "$executable" \
    --argjson rendered "$rendered" '
      {type:"_hook_activity",hook:$hook,id:$id,name:$name,input:$input,
       executable:$executable} +
      (if $rendered.user_before == "" then {} else
        {user_text:$rendered.user_before} end)'
}

sf_hooks_id() {
  local maximum=0
  if [[ -n ${SF_HOOK_SESSION-} ]]; then
    maximum=$(jq -Rrs '
      [split("\n")[] | fromjson? | select(.type == "hook_result") | .id | tonumber] |
      max // 0
    ' "$SF_HOOK_SESSION") || return
  fi
  [[ $maximum == <-> ]] || return 1
  (( maximum > SF_HOOK_ID )) && SF_HOOK_ID=$maximum
  REPLY=$(( ++SF_HOOK_ID ))
}

# Every template variable must resolve, so a hook that has not run yet renders
# against empty output rather than against no output at all.
sf_hooks_render() {
  local hook=$1 render=$2 name=$3 input=$4 stdout_file=${5-} stderr_file=${6-}
  integer exit_code=${7:-0}
  local output='{"stdout":"","stderr":"","exit_code":0}'
  [[ -z $stdout_file ]] || output=$(jq -nc \
    --rawfile stdout "$stdout_file" --rawfile stderr "$stderr_file" \
    --argjson exit_code "$exit_code" \
    '{stdout:$stdout,stderr:$stderr,exit_code:$exit_code}') || return 1
  REPLY=$(sf_jq -nc --argjson render "$render" --arg hook "$hook" --arg name "$name" \
    --argjson input "$input" --argjson output "$output" '
      include "lib/render";
      ({render:$render,name:$name,input:$input,output:$output} |
        render_execution) as $rendered |
      $rendered + {model_text:(if $rendered.model_after == "" then "" else
        "<hook name=\"" + $hook + "\">\n<context script=\"" + $name + "\">" +
        $rendered.model_after + "</context>\n</hook>" end)}
    ') || return 1
}

sf_hooks_append() {
  local session=$1 record=$2
  sf_session_append "$session" "$record" || {
    SF_HOOK_ERROR=$SF_SESSION_ERROR
    return 1
  }
  if (( SF_HOOK_JSONL )) && ! print -r -- "$record"; then
    SF_HOOK_ERROR='cannot emit hook record'
    return 1
  fi
}

sf_hooks_turn_state_create() {
  [[ -z $SHELLFISH_TURN_STATE ]] || return 0
  sf_scratch_create turns turn || {
    sf_hooks_fail 'cannot prepare hook turn state'
    return
  }
  SHELLFISH_TURN_STATE=$REPLY
  SF_HOOK_TURN_STATE_TEMP=$SHELLFISH_TURN_STATE
}

sf_hooks_turn_state_cleanup() {
  [[ -z $SF_HOOK_TURN_STATE_TEMP ]] ||
    rm -rf -- "$SF_HOOK_TURN_STATE_TEMP" 2>/dev/null || true
  SF_HOOK_TURN_STATE_TEMP=''
  unset SHELLFISH_TURN_STATE
}

sf_hooks_run() {
  local hook=$2 label=$2
  [[ $hook != pre_tool_use ]] || label=pre-tool

  SF_HOOK_ERROR=''
  (( ${+SF_HOOK_COUNTS[$hook]} )) || {
    sf_hooks_fail "unknown hook: $hook"
    return
  }
  if (( ! SF_HOOK_COUNTS[$hook] )); then
    sf_hooks_reset
    reply=( 1 0 '' '' )
    return 0
  fi
  sf_hooks_fail "$label hooks are unavailable"
}

sf_hooks_result_record() {
  local hook=$1 id=$2 name=$3 executable=$4 input=$5 rendered=$6
  integer exit_code=$7
  REPLY=$(sf_jq -nc --arg hook "$hook" --arg id "$id" --arg name "$name" \
      --arg executable "$executable" --argjson input "$input" \
      --argjson rendered "$rendered" --argjson exit_code "$exit_code" '
        include "lib/session/read";
        {type:"hook_result",lifecycle:$hook,id:$id,name:$name,input:$input,
          executable:$executable,exit_code:$exit_code} +
        (if $rendered.user_after == "" then {} else
          {user_text:$rendered.user_after} end) +
        (if $rendered.model_text == "" then {} else
          {model_text:$rendered.model_text} end) as $result |
        if ($result | canonical_hook_result)
        then $result
        else error("invalid hook result") end
      ') || {
    SF_HOOK_ERROR="hook script returned invalid result: $executable"
    return 1
  }
}

sf_hooks_session_start() {
  sf_hooks_run "$1" session_start '' reject 0 1 || return
  reply=()
}
