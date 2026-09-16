emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/hooks.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

sf_run_hook_match() {
  local session=$1 command=$2 selected=$3 max_capture=$4 env_file=$5 model=$6
  local input_file=$7 lifecycle=$8 turn_state=$9
  shift 9
  sf_hook_invoke "$session" "$SF_SESSION[runtime]" "$command" "$selected" "$max_capture" \
    "$env_file" "$model" "$SF_SESSION[cwd]" "$input_file" "$lifecycle" "$turn_state" \
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
  sf_hook_project "$SF_SESSION[runtime]" "$lifecycle" "$content" || {
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
    sf_hook_name "$command"
    name=$REPLY
    sf_hook_activity "$lifecycle" "$id" "$name" "$command" "$content" \
      "$render" || { error='cannot prepare hook activity'; break; }
    clear=$reply[2]
    input_json=$reply[3]
    sf_run_emit "$REPLY" || { error='cannot emit hook activity'; break; }
    invoke_status=0
    sf_hook_invoke "$session" "$SF_SESSION[runtime]" "$command" "$selected" "$max_capture" \
      "$env_file" "$model" "$SF_SESSION[cwd]" "$input_file" "$lifecycle" "$turn_state" \
      "$render" "$id" "$name" "$input_json" "$@" || invoke_status=$?
    if (( invoke_status )); then
      if (( invoke_status == 129 || invoke_status == 130 || invoke_status == 143 )); then
        SF_RUN[signal_status]=$invoke_status
      fi
      error=${SF_HOOK_ERROR:-cannot run $lifecycle hook}
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
