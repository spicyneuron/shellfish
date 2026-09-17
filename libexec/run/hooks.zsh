emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_scratch_create] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

sf_run_hook_name() {
  local name=$1
  [[ ${name:t} != run ]] || name=${name:h}
  REPLY=${name:t}
}

sf_run_hook_activity() {
  local lifecycle=$1 id=$2 name=$3 executable=$4 input=$5 render=$6 projected
  local input_option=--arg
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

sf_run_hook_project() {
  local session=$1 runtime=$2 lifecycle=$3 content=$4 projected
  local -a fields
  projected=$(jq -jRs --argjson runtime "$runtime" --arg lifecycle "$lifecycle" \
    --arg input "$content" '
      def field: ., "\u0000";
      ([split("\n")[1:][] | fromjson? | select(.type == "hook_result") | .id | tonumber] |
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
    ' "$session" 2>/dev/null) || return 1
  fields=( "${(@0)${projected%$'\0'}}" )
  (( ${#fields} >= 5 && (${#fields} - 5) % 4 == 0 )) && [[ $fields[-1] == ok ]] || return 1
  reply=( "${(@)fields[1,-2]}" )
}

sf_run_hook_invoke() {
  setopt local_options no_err_exit
  local session=$1 runtime=$2 command=$3 selected=$4 max_capture=$5 env_file=$6 model=$7
  local cwd=$8 input=$9 lifecycle=${10} turn_state=${11} render=${12} id=${13}
  local name=${14} input_json=${15}
  shift 15
  local config_dir='' directory projected capture_error=''
  local -a arguments environment fields process

  [[ -z $env_file ]] || config_dir=${env_file:h}
  [[ -f $command && -x $command ]] || {
    SF_RUN_HOOK_ERROR="hook command is not executable: $command"
    return 1
  }
  sf_environment_load "$env_file" "$selected" || {
    SF_RUN_HOOK_ERROR=$SF_ENVIRONMENT_ERROR
    return 1
  }
  arguments=()
  for selected in ${=SF_RUN[env_names]}; do arguments+=( -u "$selected" ); done
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
    environment+=( "SHELLFISH_TURN_ID=$SF_RUN[turn_id]" "SHELLFISH_TURN_STATE=$turn_state" )
  else
    arguments=( -u SHELLFISH_TURN_ID -u SHELLFISH_TURN_STATE "${arguments[@]}" )
  fi
  sf_scratch_create hooks capture || {
    SF_RUN_HOOK_ERROR='cannot prepare hook capture'
    return 1
  }
  directory=$REPLY
  if ! sf_process_run "$directory" "${cwd:A}" "${input:A}" "$max_capture" \
      /usr/bin/env -- "${environment[@]}" /usr/bin/env "${arguments[@]}"; then
    rm -rf -- "$directory"
    SF_RUN_HOOK_ERROR=$SF_PROCESS_ERROR
    return 1
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
      include "libexec/run/hooks"; include "lib/runtime"; include "lib/session";
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
       elif $outcome.control.action? == "session_update" then ($outcome.control.runtime | tojson)
       else "" end | field),
      (if $result == null then "" else ($result | tojson) end | field),
      ($outcome.states | length | tostring | field),
      ($outcome.states[] | tojson | field)
    ' 2>/dev/null) || {
    rm -rf -- "$directory"
    SF_RUN_HOOK_ERROR='cannot decode hook result'
    return 1
  }
  rm -rf -- "$directory"
  fields=( "${(@0)${projected%$'\0'}}" )
  (( ${#fields} >= 8 && ${#fields} == 8 + fields[8] )) || {
    SF_RUN_HOOK_ERROR='cannot decode hook result'
    return 1
  }
  reply=( "${fields[@]}" )
}

sf_run_hook_match() {
  local session=$1 command=$2 selected=$3 max_capture=$4 env_file=$5 model=$6
  local input_file=$7 lifecycle=$8 turn_state=$9
  shift 9
  sf_run_hook_invoke "$session" "$SF_RUN[runtime]" "$command" "$selected" "$max_capture" \
    "$env_file" "$model" "$SF_RUN[cwd]" "$input_file" "$lifecycle" "$turn_state" \
    '' '' '' '' "$@" || return 2
  (( reply[2] + reply[3] + reply[4] == 0 && (reply[1] == 0 || reply[1] == 1) )) || return 2
  (( reply[1] == 0 ))
}

# Return decision fields in reply after appending every accepted record.
sf_run_hooks() {
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local input_file input_json command selected match_command name render record clear
  local error='' decision=proceed reason='' action='' payload=''
  local max_capture env_file model
  local -a plan completion states
  integer offset id exit_code invoke_status match_status state_count

  SF_RUN_HOOK_ERROR=''
  sf_scratch_file hooks input || { SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"; return 1; }
  input_file=$REPLY
  print -rn -- "$content" >"$input_file" || {
    rm -f -- "$input_file"
    SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"
    return 1
  }
  sf_run_hook_project "$session" "$SF_RUN[runtime]" "$lifecycle" "$content" || {
    rm -f -- "$input_file"
    SF_RUN_HOOK_ERROR="cannot inspect $lifecycle hooks"
    return 1
  }
  plan=( "${reply[@]}" )
  id=$plan[1]
  max_capture=$plan[2]
  env_file=$plan[3]
  model=$plan[4]
  for (( offset = 5; offset <= ${#plan}; offset += 4 )); do
    command=$plan[offset]
    selected=$plan[offset+1]
    match_command=$plan[offset+2]
    render=$plan[offset+3]
    if [[ -n $match_command ]]; then
      sf_run_hook_match "$session" "$match_command" "$selected" "$max_capture" \
        "$env_file" "$model" "$input_file" "$lifecycle" "$turn_state" "$@"
      match_status=$?
      (( match_status == 0 )) || {
        (( match_status == 1 )) && continue
        error="hook match command failed: $match_command"
        break
      }
    fi
    sf_run_hook_name "$command"
    name=$REPLY
    sf_run_hook_activity "$lifecycle" "$id" "$name" "$command" "$content" \
      "$render" || { error='cannot prepare hook activity'; break; }
    clear=$reply[2]
    input_json=$reply[3]
    sf_run_emit "$REPLY" || { error='cannot emit hook activity'; break; }
    invoke_status=0
    sf_run_hook_invoke "$session" "$SF_RUN[runtime]" "$command" "$selected" "$max_capture" \
      "$env_file" "$model" "$SF_RUN[cwd]" "$input_file" "$lifecycle" "$turn_state" \
      "$render" "$id" "$name" "$input_json" "$@" || invoke_status=$?
    if (( invoke_status )); then
      if (( invoke_status == 129 || invoke_status == 130 || invoke_status == 143 )); then
        SF_RUN[signal_status]=$invoke_status
      fi
      error=${SF_RUN_HOOK_ERROR:-cannot run $lifecycle hook}
      break
    fi
    completion=( "${reply[@]}" )
    exit_code=$completion[1]
    state_count=$completion[8]
    states=( "${(@)completion[9,$(( 8 + state_count ))]}" )
    for record in "${states[@]}"; do
      sf_run_append "$session" "$record" || { error=$REPLY; break 2; }
    done
    record=$completion[7]
    if [[ -n $record ]]; then
      sf_run_append "$session" "$record" || { error=$REPLY; break; }
      (( id += 1 ))
    elif [[ -n $clear ]]; then
      sf_run_emit "$clear" || { error='cannot emit hook clear'; break; }
    fi
    if [[ -n $completion[2] ]]; then
      error="$lifecycle hook returned invalid control: $command"
      break
    fi
    action=$completion[4]
    reason=$completion[5]
    payload=$completion[6]
    case $exit_code in
      0) ;;
      10)
        case $lifecycle in
          user_prompt_submit) decision=handled ;;
          permission_request|pre_tool_use) decision=deny ;;
          stop) decision=continue ;;
          *) error="$lifecycle hook returned unsupported status" ;;
        esac
        ;;
      11)
        case $lifecycle in
          user_prompt_submit)
            decision=handled
            ;;
          permission_request)
            [[ $decision == deny ]] || decision=$action
            ;;
          pre_tool_use) decision=deny ;;
          stop) decision=continue ;;
          *) error="$lifecycle hook returned unsupported status" ;;
        esac
        [[ -n $error ]] || break
        ;;
      *) error="hook script failed with status $exit_code: $command" ;;
    esac
    [[ -z $error || -z $completion[3] ]] || error+=": $completion[3]"
    [[ -z $error ]] || break
  done
  rm -f -- "$input_file"
  if [[ -n $error ]]; then
    SF_RUN_HOOK_ERROR=$error
    return 1
  fi
  reply=( "$decision" "$action" "$reason" )
  [[ $action != (handoff|session_update) ]] || reply+=( "$payload" )
}
