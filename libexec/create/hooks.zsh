emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/hooks.zsh"

sf_create_event() {
  (( ! SF_CREATE_JSONL )) || print -r -- "$1"
}

sf_create_start_hooks() {
  local session=$1 input input_json command selected name render record clear error=''
  local max_capture env_file model
  local -a plan completion states
  integer offset id exit_code invoke_status state_count
  sf_scratch_file hooks input || {
    sf_die 'cannot prepare session_start hook input'
    return 1
  }
  input=$REPLY
  : >"$input" || { rm -f -- "$input"; sf_die 'cannot prepare session_start hook input'; return 1; }
  sf_hook_project "$SF_SESSION[runtime]" session_start '' || {
    rm -f -- "$input"
    sf_die 'cannot inspect session_start hooks'
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
    render=$plan[offset+3]
    sf_hook_name "$command"
    name=$REPLY
    sf_hook_activity session_start "$id" "$name" "$command" '' "$render" || {
      error="cannot prepare hook activity: $command"
      break
    }
    clear=$reply[2]
    input_json=$reply[3]
    sf_create_event "$REPLY" || { error='cannot emit hook activity'; break; }
    invoke_status=0
    sf_hook_invoke "$session" "$SF_SESSION[runtime]" "$command" "$selected" "$max_capture" \
      "$env_file" "$model" "$SF_SESSION[cwd]" "$input" session_start '' \
      "$render" "$id" "$name" "$input_json" || invoke_status=$?
    if (( invoke_status )); then
      if (( invoke_status == 130 )); then rm -f -- "$input"; return 130; fi
      error=${SF_HOOK_ERROR:-cannot run session_start hook}
      break
    fi
    completion=( "${reply[@]}" )
    exit_code=$completion[1]
    state_count=$completion[8]
    states=( "${(@)completion[9,$(( 8 + state_count ))]}" )
    for record in "${states[@]}"; do
      sf_session_append "$session" "$record" || { error=$SF_SESSION_ERROR; break 2; }
      sf_create_event "$record" || { error='cannot emit hook state'; break 2; }
    done
    record=$completion[7]
    if [[ -n $record ]]; then
      sf_session_append "$session" "$record" || { error=$SF_SESSION_ERROR; break; }
      sf_create_event "$record" || { error='cannot emit hook result'; break; }
      (( id += 1 ))
    elif [[ -n $clear ]]; then
      sf_create_event "$clear" || { error='cannot emit hook clear'; break; }
    fi
    if [[ $completion[2] == decode ]]; then
      error="session_start hook returned invalid control: $command"
    elif [[ $completion[2] == lifecycle ]]; then
      error="session_start hook returned unexpected control: $command"
    elif (( exit_code == 10 || exit_code == 11 )); then
      error='session_start hook returned unsupported status'
    elif (( exit_code != 0 )); then
      error="hook script failed with status $exit_code: $command"
    fi
    [[ -z $error || -z $completion[3] ]] || error+=": $completion[3]"
    [[ -z $error ]] || break
  done
  rm -f -- "$input"
  [[ -z $error ]] || { sf_die "$error"; return 1; }
}
