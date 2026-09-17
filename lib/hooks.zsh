emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_prepare] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_scratch_create] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_HOOK_ERROR=''

sf_hook_fail() {
  SF_HOOK_ERROR=$1
  REPLY=''
  return 1
}

sf_hook_name() {
  local path=$1 name=$1
  [[ ${name:t} != run ]] || name=${name:h}
  REPLY=${name:t}
}

sf_hook_activity() {
  local lifecycle=$1 id=$2 name=$3 executable=$4 input=$5 render=$6
  local projected input_option=--arg
  [[ $lifecycle != (permission_request|pre_tool_use|post_tool_use) ]] || input_option=--argjson
  projected=$(sf_jq -jcn --arg lifecycle "$lifecycle" --arg id "$id" --arg name "$name" \
    --arg executable "$executable" "$input_option" input "$input" --argjson render "$render" '
      include "lib/runtime";
      (render_component($render;$name;$input;{stdout:"",stderr:"",exit_code:0}) |
       .initial_user_text // "") as $user_text |
      ({type:"_hook_activity",hook:$lifecycle,id:$id,name:$name,input:$input,
        executable:$executable} +
       (if $user_text == "" then {} else {user_text:$user_text} end)) as $activity |
      ($activity | tojson), "\u0000",
      (if $user_text == "" then "" else ($activity | del(.user_text) | tojson) end), "\u0000",
      ($input | tojson), "\u0000"
    ') || return
  reply=( "${(@0)${projected%$'\0'}}" )
  (( ${#reply} == 3 )) || return 1
  REPLY=$reply[1]
}

sf_hook_project() {
  local runtime=$1 lifecycle=$2 content=$3 projected
  local -a fields
  projected=$(printf '%s\n' "${SF_SESSION_RECORDS[@]:1}" |
    jq -jRs --argjson runtime "$runtime" --arg lifecycle "$lifecycle" \
    --arg input "$content" '
      def field: ., "\u0000";
      ([split("\n")[] | fromjson? | select(.type == "hook_result") | .id | tonumber] |
        ((max // 0) + 1) | tostring | field),
      ($runtime.harness.max_capture_bytes | tostring | field),
      ($runtime.backend.env_file | field),
      ($runtime.profile.request.model | field),
      ($runtime.harness[$lifecycle][]? |
        (.match.pattern? // "") as $pattern |
        select($pattern == "" or ($input | test($pattern))) |
        (.command | field),
        (.environment | join(" ") | field),
        (.match.command? // "" | field),
        (.render | tojson | field)),
      ("ok" | field)
    ' 2>/dev/null) || return 1
  fields=( "${(@0)${projected%$'\0'}}" )
  (( ${#fields} >= 5 && (${#fields} - 5) % 4 == 0 )) && [[ $fields[-1] == ok ]] || return 1
  reply=( "${(@)fields[1,-2]}" )
}

# Return match metadata or one projected hook completion in reply.
sf_hook_invoke() {
  setopt local_options no_err_exit
  local session=$1 runtime=$2 command=$3 selected=$4 max_capture=$5 env_file=$6 model=$7
  local cwd=$8 input=$9 lifecycle=${10} turn_state=${11} render=${12} id=${13}
  local name=${14} input_json=${15}
  shift 15
  local config_dir='' directory projected capture_error=''
  local -a arguments environment fields process

  SF_HOOK_ERROR=''
  [[ -z $env_file ]] || config_dir=${env_file:h}
  [[ -f $command && -x $command ]] || {
    sf_hook_fail "hook command is not executable: $command"
    return
  }
  sf_environment_prepare "$runtime" "$selected" || {
    sf_hook_fail "$SF_ENVIRONMENT_ERROR"
    return
  }
  arguments=()
  for selected in $SF_ENVIRONMENT_NAMES; do arguments+=( -u "$selected" ); done
  arguments+=( "${SF_ENVIRONMENT_VALUES[@]}" "$command" "$@" )
  environment=(
    "SHELLFISH_SESSION=${session:A}"
    "SHELLFISH_MAX_CAPTURE_BYTES=$max_capture"
    "SHELLFISH_MODEL=$model"
    "SHELLFISH_EXECUTABLE=$SF_ENTRY"
    "SHELLFISH_MODE=${SHELLFISH_MODE-}"
    "SHELLFISH_VERBOSE=${SHELLFISH_VERBOSE:-0}"
    "SHELLFISH_CONFIG_DIR=$config_dir"
  )
  if [[ $lifecycle != session_start ]]; then
    environment+=( "SHELLFISH_TURN_ID=$SF_SESSION[turn_id]" "SHELLFISH_TURN_STATE=$turn_state" )
  else
    arguments=( -u SHELLFISH_TURN_ID -u SHELLFISH_TURN_STATE "${arguments[@]}" )
  fi
  sf_scratch_create hooks capture || {
    sf_hook_fail 'cannot prepare hook capture'
    return
  }
  directory=$REPLY
  if ! sf_process_run "$directory" "${cwd:A}" "${input:A}" "$max_capture" \
      /usr/bin/env -- "${environment[@]}" /usr/bin/env "${arguments[@]}"; then
    rm -rf -- "$directory"
    sf_hook_fail "$SF_PROCESS_ERROR"
    return
  fi
  process=( "${reply[@]}" )
  if (( process[3] + process[4] + process[5] > max_capture )); then
    capture_error='hook output exceeds capture limit'
  fi
  if (( process[2] )); then
    rm -rf -- "$directory"
    return $process[1]
  fi
  if [[ -z $id ]]; then
    rm -rf -- "$directory"
    reply=( "$process[1]" "$process[3]" "$process[4]" "$process[5]" )
    return
  fi
  projected=$(sf_jq -jcn --argjson exit_code "$process[1]" \
    --rawfile stdout "$directory/stdout" --rawfile stderr "$directory/stderr" \
    --slurpfile controls "$directory/control" --arg capture_error "$capture_error" \
    --arg lifecycle "$lifecycle" --arg id "$id" --arg name "$name" \
    --arg executable "$command" --argjson input "$input_json" --argjson render "$render" '
      include "lib/hooks"; include "lib/runtime"; include "lib/session";
      def field: ., "\u0000";
      hook_outcome($exit_code;$stdout;$stderr;$controls;$capture_error) |
      . as $outcome |
      ($outcome | hook_control_error($lifecycle)) as $control_error |
      (if $outcome.exit_code != 0 or $outcome.stdout != "" or $outcome.stderr != "" then
        render_component($render;$name;$input;$outcome) as $rendered |
        ({type:"hook_result",lifecycle:$lifecycle,id:$id,name:$name,input:$input,
          executable:$executable,exit_code:$outcome.exit_code} +
         (if $rendered.user_text == null then {} else {user_text:$rendered.user_text} end) +
         (if $rendered.model_text == null then {} else {model_text:$rendered.model_text} end)) as $result |
        if $result | canonical_hook_result then $result else error("invalid result") end
       else null end) as $result |
      ($outcome.exit_code | tostring | field),
      ($control_error | field),
      ($outcome.stderr | field),
      (if $control_error == "" then $outcome.control.action? // "" else "" end | field),
      (if $control_error == "" then $outcome.control.reason? // "" else "" end | field),
      (if $control_error != "" then ""
       elif $outcome.control.action? == "handoff" then ($outcome.control.argv | tojson)
       elif $outcome.control.action? == "session_update" then ($outcome.control.patch | tojson)
       else "" end | field),
      (if $result == null then "" else ($result | tojson) end | field),
      ($outcome.states | length | tostring | field),
      ($outcome.states[] | tojson | field)
    ' 2>/dev/null) || {
    rm -rf -- "$directory"
    sf_hook_fail 'cannot decode hook result'
    return
  }
  rm -rf -- "$directory"
  fields=( "${(@0)${projected%$'\0'}}" )
  (( ${#fields} >= 8 && ${#fields} == 8 + fields[8] )) || {
    sf_hook_fail 'cannot decode hook result'
    return
  }
  reply=( "${fields[@]}" )
}
