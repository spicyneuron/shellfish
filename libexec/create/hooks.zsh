emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/hooks.zsh"

sf_create_event() {
  (( ! SF_CREATE_JSONL )) || print -r -- "$1"
}

sf_create_start_hooks() {
  local session=$1 input component command name id render activity outcome record clear error=''
  local projection state_projection
  local -a components states
  integer exit_code
  sf_scratch_file hooks input || {
    sf_die 'cannot prepare session_start hook input'
    return 1
  }
  input=$REPLY
  : >"$input" || { rm -f -- "$input"; sf_die 'cannot prepare session_start hook input'; return 1; }
  projection=$(jq -c '.harness.session_start[]?' <<<"$SF_SESSION[runtime]") || {
    rm -f -- "$input"
    sf_die 'cannot inspect session_start hooks'
    return 1
  }
  components=( ${(@f)projection} )
  for component in "${components[@]}"; do
    command=$(jq -r '.command' <<<"$component") || error='cannot inspect session_start hook'
    render=$(jq -c '.render' <<<"$component") || error='cannot inspect session_start hook'
    [[ -z $error ]] || break
    sf_hook_name "$command"
    name=$REPLY
    sf_hook_next_id || { error='cannot allocate hook invocation ID'; break; }
    id=$REPLY
    sf_hook_activity session_start "$id" "$name" "$command" '""' "$render" || {
      error="cannot prepare hook activity: $command"
      break
    }
    activity=$REPLY
    sf_create_event "$activity" || { error='cannot emit hook activity'; break; }
    integer invoke_status=0
    sf_hook_invoke "$session" "$SF_SESSION[runtime]" "$component" \
      "$SF_SESSION[cwd]" "$input" session_start '' || invoke_status=$?
    if (( invoke_status )); then
      if (( invoke_status == 130 )); then rm -f -- "$input"; return 130; fi
      error=${SF_HOOK_ERROR:-cannot run session_start hook}
      break
    fi
    outcome=$REPLY
    exit_code=$(jq -r '.exit_code' <<<"$outcome") || { error='cannot inspect hook result'; break; }
    state_projection=$(jq -c '.states[]' <<<"$outcome") || { error='cannot inspect hook state'; break; }
    states=( ${(@f)state_projection} )
    for record in "${states[@]}"; do
      sf_session_append "$session" "$record" || { error=$SF_SESSION_ERROR; break 2; }
      sf_create_event "$record" || { error='cannot emit hook state'; break 2; }
    done
    if jq -e '.exit_code != 0 or .stdout != "" or .stderr != ""' <<<"$outcome" >/dev/null; then
      sf_hook_result session_start "$id" "$name" "$command" '""' "$render" "$outcome" || {
        error="hook script returned invalid result: $command"
        break
      }
      record=$REPLY
      sf_session_append "$session" "$record" || { error=$SF_SESSION_ERROR; break; }
      sf_create_event "$record" || { error='cannot emit hook result'; break; }
    elif jq -e 'has("user_text")' <<<"$activity" >/dev/null; then
      clear=$(jq -c 'del(.user_text)' <<<"$activity") || { error='cannot prepare hook clear'; break; }
      sf_create_event "$clear" || { error='cannot emit hook clear'; break; }
    fi
    if [[ -n $(jq -r '.control_error // empty' <<<"$outcome") ]]; then
      error="session_start hook returned invalid control: $command"
    elif ! jq -e '.control == {}' <<<"$outcome" >/dev/null; then
      error="session_start hook returned unexpected control: $command"
    elif (( exit_code == 10 || exit_code == 11 )); then
      error='session_start hook returned unsupported status'
    elif (( exit_code != 0 )); then
      error="hook script failed with status $exit_code: $command"
    fi
    [[ -z $error || -z $(jq -r '.stderr' <<<"$outcome") ]] ||
      error+=": $(jq -r '.stderr' <<<"$outcome")"
    [[ -z $error ]] || break
  done
  rm -f -- "$input"
  [[ -z $error ]] || { sf_die "$error"; return 1; }
}
