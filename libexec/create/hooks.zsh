emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

source "$SF_ROOT/lib/hooks.zsh"

sf_create_event() {
  (( ! SF_CREATE_JSONL )) || print -r -- "$1"
}

sf_create_hook_id() {
  local maximum
  maximum=$(printf '%s\n' "${SF_SESSION_RECORDS[@]:1}" | jq -Rs '
    [split("\n")[] | fromjson? | select(.type == "hook_result") | .id | tonumber] |
    max // 0
  ') || return
  REPLY=$(( maximum + 1 ))
}

sf_create_append() {
  sf_session_append "$1" "$2" || return
  sf_create_event "$2"
}

sf_create_start_hooks() {
  local session=$1 input component command name id running activity outcome record error=''
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
    running=$(jq -r '.running' <<<"$component") || error='cannot inspect session_start hook'
    [[ -z $error ]] || break
    sf_hook_name "$command"
    name=$REPLY
    sf_create_hook_id || { error='cannot allocate hook invocation ID'; break; }
    id=$REPLY
    running=$(sf_jq -nr --arg template "$running" --arg name "$name" '
      include "lib/render";
      render_running($template;$name;"")
    ') || { error="cannot render hook activity: $command"; break; }
    activity=$(jq -cn --arg id "$id" --arg name "$name" --arg executable "$command" \
      --arg running "$running" '
        {type:"_hook_activity",hook:"session_start",id:$id,name:$name,input:"",
         executable:$executable} +
        (if $running == "" then {} else {user_text:$running} end)
      ') || { error='cannot prepare hook activity'; break; }
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
      sf_create_append "$session" "$record" || { error=$SF_SESSION_ERROR; break 2; }
    done
    if jq -e '.exit_code != 0 or .stdout != "" or .stderr != ""' <<<"$outcome" >/dev/null; then
      record=$(sf_jq -cn --arg id "$id" --arg name "$name" --arg executable "$command" \
        --argjson outcome "$outcome" '
          include "lib/session/read";
          ({type:"hook_result",lifecycle:"session_start",id:$id,name:$name,input:"",
            executable:$executable,exit_code:$outcome.exit_code} +
           (if $outcome.stderr == "" then {} else {user_text:$outcome.stderr} end) +
           (if $outcome.stdout == "" then {} else {model_text:$outcome.stdout} end)) as $result |
          if $result | canonical_hook_result then $result else error("invalid result") end
        ') || { error="hook script returned invalid result: $command"; break; }
      sf_create_append "$session" "$record" || { error=$SF_SESSION_ERROR; break; }
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
