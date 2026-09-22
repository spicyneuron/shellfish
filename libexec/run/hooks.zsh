emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_scratch_create] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

# Values shared by every hook of one lifecycle, and the outcome of the hook
# that ran last, both keyed by name.
typeset -gA SF_HOOK_PLAN=() SF_HOOK_RESULT=()

sf_run_hook_name() {
  local name=$1
  [[ ${name:t} != run ]] || name=${name:h}
  REPLY=${name:t}
}

sf_run_hook_activity() {
  local lifecycle=$1 id=$2 name=$3 executable=$4 input=$5 render=$6
  local input_option=--arg
  [[ $lifecycle != (permission_request|pre_tool_use|post_tool_use) ]] || input_option=--argjson
  sf_jq_fields 3 -cn --arg lifecycle "$lifecycle" --arg id "$id" --arg name "$name" \
    --arg executable "$executable" "$input_option" input "$input" --argjson render "$render" '
      include "lib/runtime";
      (render_component($render;$name;$input;{stdout:"",stderr:"",exit_code:0}) |
       .initial_user_text // "") as $user_text |
      ({type:"_hook_activity",hook:$lifecycle,id:$id,name:$name,input:$input,
        executable:$executable} +
       (if $user_text == "" then {} else {user_text:$user_text} end)) as $activity |
      ($activity | tojson), "\u0000",
      (if $user_text == "" then "" else ($activity | del(.user_text) | tojson) end), "\u0000",
      ($input | tojson), "\u0000", "ok", "\u0000"
    ' || return 1
  REPLY=$reply[1]
}

# Shared values land in SF_HOOK_PLAN; the matching hooks follow in reply as
# groups of command, environment, match command, and render template.
sf_run_hook_project() {
  local runtime=$1 lifecycle=$2 content=$3
  sf_jq_fields 0 -rn --argjson runtime "$runtime" --arg lifecycle "$lifecycle" \
    --arg input "$content" '
      include "lib/runtime";
      def field: ., "\u0000";
      def entry($key; $value): ($key | field), ($value | field);
      entry("max_capture"; $runtime.harness.max_capture_bytes | tostring),
      entry("env_file"; $runtime.backend.env_file),
      entry("model"; $runtime.profile.request.model),
      entry("environment_names"; declared_environment($runtime)),
      ($runtime.harness[$lifecycle][]? |
        (.match.pattern? // "") as $pattern |
        select($pattern == "" or ($input | test($pattern))) |
        (.command | field),
        (.environment | join(" ") | field),
        (.match.command? // "" | field),
        (.render | tojson | field)),
      ("ok" | field)
    ' || return 1
  SF_HOOK_PLAN=( "${(@)reply[1,8]}" )
  reply=( "${(@)reply[9,-1]}" )
}

sf_run_hook_invoke() {
  setopt local_options no_err_exit
  local session=$1 command=$2 selected=$3 input=$4 lifecycle=$5 turn_state=$6
  local render=$7 id=$8 name=$9 input_json=${10}
  shift 10
  local env_file=$SF_HOOK_PLAN[env_file] config_dir='' directory capture_error=''
  local -a arguments environment process
  integer max_capture=$SF_HOOK_PLAN[max_capture]

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
  for selected in ${=SF_HOOK_PLAN[environment_names]}; do arguments+=( -u "$selected" ); done
  arguments+=( "${SF_ENVIRONMENT_VALUES[@]}" "$command" "$@" )
  environment=(
    "SHELLFISH_SESSION=${session:A}"
    "SHELLFISH_MAX_CAPTURE_BYTES=$max_capture"
    "SHELLFISH_MODEL=$SF_HOOK_PLAN[model]"
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
  if ! sf_process_run "$directory" "${SF_RUN[cwd]:A}" "${input:A}" "$max_capture" \
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
    SF_HOOK_RESULT=( exit_code "$process[1]" stdout_bytes "$process[3]"
      stderr_bytes "$process[4]" control_bytes "$process[5]" )
    return
  fi
  sf_jq_fields 0 -cn --argjson exit_code "$process[1]" \
    --rawfile stdout "$directory/stdout" --rawfile stderr "$directory/stderr" \
    --slurpfile controls "$directory/control" --arg capture_error "$capture_error" \
    --arg lifecycle "$lifecycle" --arg id "$id" --arg name "$name" \
    --argjson input "$input_json" --argjson render "$render" '
      include "libexec/run/hooks"; include "lib/runtime"; include "lib/session";
      def field: ., "\u0000";
      def entry($key; $value): ($key | field), ($value | field);
      hook_outcome($exit_code;$stdout;$stderr;$controls;$capture_error) |
      . as $outcome |
      ($outcome | hook_control_error($lifecycle)) as $control_error |
      (if $outcome.exit_code != 0 or $outcome.stdout != "" or $outcome.stderr != "" then
        render_component($render;$name;$input;$outcome) as $rendered |
        ({type:"hook_result",lifecycle:$lifecycle,id:$id,name:$name,input:$input,
          exit_code:$outcome.exit_code} +
         (if $rendered.user_text == null then {} else {user_text:$rendered.user_text} end) +
         (if $rendered.model_text == null then {} else {model_text:$rendered.model_text} end)) as $result |
        if $result | canonical_hook_result then $result else error("invalid result") end
       else null end) as $result |
      entry("exit_code"; $outcome.exit_code | tostring),
      entry("control_error"; $control_error),
      entry("stderr"; $outcome.stderr),
      entry("action";
        if $control_error == "" then $outcome.control.action? // "" else "" end),
      entry("reason";
        if $control_error == "" then $outcome.control.reason? // "" else "" end),
      entry("payload";
        if $control_error != "" then ""
        elif $outcome.control.action? == "handoff" then ($outcome.control.argv | tojson)
        elif $outcome.control.action? == "session_update" then ($outcome.control.runtime | tojson)
        else "" end),
      entry("record"; if $result == null then "" else ($result | tojson) end),
      ($outcome.states[] | tojson | field),
      ("ok" | field)
    ' || {
    rm -rf -- "$directory"
    SF_RUN_HOOK_ERROR='cannot decode hook result'
    return 1
  }
  rm -rf -- "$directory"
  # Seven named values, then any state records the hook wrote.
  SF_HOOK_RESULT=( "${(@)reply[1,14]}" )
  reply=( "${(@)reply[15,-1]}" )
}

# A match command decides by status alone and may write nothing.
sf_run_hook_match() {
  local session=$1 command=$2 selected=$3 input_file=$4 lifecycle=$5 turn_state=$6
  shift 6
  sf_run_hook_invoke "$session" "$command" "$selected" "$input_file" "$lifecycle" \
    "$turn_state" '' '' '' '' "$@" || return 2
  (( SF_HOOK_RESULT[stdout_bytes] + SF_HOOK_RESULT[stderr_bytes] +
     SF_HOOK_RESULT[control_bytes] == 0 &&
     (SF_HOOK_RESULT[exit_code] == 0 || SF_HOOK_RESULT[exit_code] == 1) )) || return 2
  (( SF_HOOK_RESULT[exit_code] == 0 ))
}

# Return decision fields in reply after appending every accepted record.
sf_run_hooks() {
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local input_file input_json command selected match_command name render record clear
  local error='' decision=proceed reason='' action='' payload=''
  local -a plan states
  integer offset id exit_code invoke_status match_status

  SF_RUN_HOOK_ERROR=''
  if (( SF_RUN[hooks_known] )) &&
      [[ " $SF_RUN[hooks] " != *" $lifecycle "* ]]; then
    reply=( proceed '' '' )
    return 0
  fi
  sf_run_hook_project "$SF_RUN[runtime]" "$lifecycle" "$content" || {
    SF_RUN_HOOK_ERROR="cannot inspect $lifecycle hooks"
    return 1
  }
  plan=( "${reply[@]}" )
  if (( ! ${#plan} )); then
    reply=( proceed '' '' )
    return 0
  fi
  sf_scratch_file hooks input || { SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"; return 1; }
  input_file=$REPLY
  print -rn -- "$content" >"$input_file" || {
    rm -f -- "$input_file"
    SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"
    return 1
  }
  id=$SF_RUN[hook_id]
  for (( offset = 1; offset <= ${#plan}; offset += 4 )); do
    command=$plan[offset]
    selected=$plan[offset+1]
    match_command=$plan[offset+2]
    render=$plan[offset+3]
    if [[ -n $match_command ]]; then
      sf_run_hook_match "$session" "$match_command" "$selected" "$input_file" \
        "$lifecycle" "$turn_state" "$@"
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
    sf_run_hook_invoke "$session" "$command" "$selected" "$input_file" "$lifecycle" \
      "$turn_state" "$render" "$id" "$name" "$input_json" "$@" || invoke_status=$?
    if (( invoke_status )); then
      if (( invoke_status == 129 || invoke_status == 130 || invoke_status == 143 )); then
        SF_RUN[signal_status]=$invoke_status
      fi
      error=${SF_RUN_HOOK_ERROR:-cannot run $lifecycle hook}
      break
    fi
    states=( "${reply[@]}" )
    exit_code=$SF_HOOK_RESULT[exit_code]
    for record in "${states[@]}"; do
      sf_run_append "$session" "$record" || { error=$REPLY; break 2; }
    done
    record=$SF_HOOK_RESULT[record]
    if [[ -n $record ]]; then
      sf_run_append "$session" "$record" || { error=$REPLY; break; }
      (( SF_RUN[hook_id] += 1 ))
      id=$SF_RUN[hook_id]
    elif [[ -n $clear ]]; then
      sf_run_emit "$clear" || { error='cannot emit hook clear'; break; }
    fi
    if [[ -n $SF_HOOK_RESULT[control_error] ]]; then
      error="$lifecycle hook returned invalid control: $command"
      break
    fi
    action=$SF_HOOK_RESULT[action]
    reason=$SF_HOOK_RESULT[reason]
    payload=$SF_HOOK_RESULT[payload]
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
    [[ -z $error || -z $SF_HOOK_RESULT[stderr] ]] || error+=": $SF_HOOK_RESULT[stderr]"
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
