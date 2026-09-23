emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

# Values shared by every hook of one lifecycle, and the running hook's outcome,
# both keyed by name.
typeset -gA SF_HOOK_PLAN=() SF_HOOK_RESULT=()

# Shared values land in SF_HOOK_PLAN; the matching hooks follow in reply as
# pairs of command and match command.
sf_run_hook_project() {
  local runtime=$1 lifecycle=$2 content=$3
  sf_jq_fields -rn --argjson runtime "$runtime" --arg lifecycle "$lifecycle" \
    --arg input "$content" '
      include "lib/fields";
      include "lib/runtime";
      entry("max_capture"; $runtime.harness.max_capture_bytes | tostring),
      entry("model"; $runtime.request.model),
      ($runtime.harness[$lifecycle][]? |
        (.match.pattern? // "") as $pattern |
        select($pattern == "" or ($input | test($pattern))) |
        (.command | field),
        (.match.command? // "" | field)),
      ("ok" | field)
    ' || return 1
  # The two named entries above fill the first four slots; hooks follow.
  SF_HOOK_PLAN=( "${(@)reply[1,4]}" )
  reply=( "${(@)reply[5,-1]}" )
}

# A settled result takes the live section's id and opens the next one.
sf_run_hook_settle() {
  sf_run_append "$SF_HOOK_RESULT[session]" "$1" || return
  (( SF_RUN[hook_id] += 1 ))
  SF_HOOK_RESULT[live]=0
}

# Apply one fd 3 line as it arrives. After an invalid line the rest are ignored
# and the hook fails at exit.
sf_run_hook_line() {
  local record
  local -A line
  [[ -z $SF_HOOK_RESULT[error] ]] || return 0
  sf_jq_fields -cn --arg line "$1" --arg lifecycle "$SF_HOOK_RESULT[lifecycle]" \
    --arg id "$SF_RUN[hook_id]" '
      include "lib/fields";
      include "lib/session";
      include "libexec/run/hooks";
      ($line | try fromjson catch null | hook_line($lifecycle; $id)) as $line |
      entry("valid"; $line != null | tostring),
      entry("final"; $line.final | tostring),
      entry("states"; [$line.states[]? | tojson] | join("\n")),
      entry("record"; $line.record | if . == null then "" else tojson end),
      entry("draft"; $line.draft | if . == null then "" else tojson end),
      entry("action"; $line.control.action // ""),
      entry("reason"; $line.control.reason // ""),
      entry("payload"; $line.control | (.argv // .runtime) |
        if . == null then "" else tojson end),
      ("ok" | field)
    ' || { SF_HOOK_RESULT[error]='cannot decode hook output'; return 1; }
  line=( "${reply[@]}" )
  [[ $line[valid] == true ]] || { SF_HOOK_RESULT[error]=invalid; return 1; }
  for record in ${(f)line[states]}; do
    sf_run_append "$SF_HOOK_RESULT[session]" "$record" ||
      { SF_HOOK_RESULT[error]=$REPLY; return 1; }
  done
  if [[ -n $line[record] ]]; then
    sf_run_hook_settle "$line[record]" || { SF_HOOK_RESULT[error]=$REPLY; return 1; }
  elif [[ -n $line[draft] ]]; then
    sf_run_emit "$line[draft]" || { SF_HOOK_RESULT[error]='cannot emit hook draft'; return 1; }
    SF_HOOK_RESULT[live]=1
  fi
  [[ $line[final] != true ]] || SF_HOOK_RESULT[final]=1
  [[ -z $line[action] ]] || SF_HOOK_RESULT+=( action "$line[action]"
    reason "$line[reason]" payload "$line[payload]" )
}

# Without a final, stdout and stderr settle as one result: the user sees both
# and the model sees stdout.
sf_run_hook_shortcut() {
  local directory=$1 record
  record=$(sf_jq -cn --rawfile stdout "$directory/stdout" --rawfile stderr "$directory/stderr" \
    --arg lifecycle "$SF_HOOK_RESULT[lifecycle]" --arg id "$SF_RUN[hook_id]" '
      {type:"hook_result",lifecycle:$lifecycle,id:$id} +
      (if $stdout + $stderr == "" then {} else {user_text:($stdout + $stderr)} end) +
      (if $stdout == "" then {} else {model_text:$stdout} end)
    ') || { REPLY='cannot decode hook result'; return 1; }
  sf_run_hook_settle "$record"
}

# HANDLER receives fd 3 lines; ":" runs a match command, which only reports.
sf_run_hook_invoke() {
  setopt local_options no_err_exit
  local session=$1 command=$2 input=$3 lifecycle=$4 turn_state=$5 handler=$6
  shift 6
  local config_dir directory error=''
  local -a environment
  local -A process
  integer max_capture=$SF_HOOK_PLAN[max_capture] output_bytes

  [[ -f $command && -x $command ]] || {
    SF_RUN_HOOK_ERROR="hook command is not executable: $command"
    return 1
  }
  sf_environment_load || {
    SF_RUN_HOOK_ERROR=$SF_ENVIRONMENT_ERROR
    return 1
  }
  config_dir=$REPLY
  # Core values follow .env values so that they win.
  environment=(
    "${SF_ENVIRONMENT_VALUES[@]}"
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
    environment=( -u SHELLFISH_TURN_ID -u SHELLFISH_TURN_STATE "${environment[@]}" )
  fi
  sf_scratch_directory hook || {
    SF_RUN_HOOK_ERROR='cannot prepare hook capture'
    return 1
  }
  directory=$REPLY
  SF_HOOK_RESULT=( session "$session" lifecycle "$lifecycle" error '' final 0 live 0
    action '' reason '' payload '' )
  if ! sf_process_run "$directory" "${SF_RUN[cwd]:A}" "${input:A}" "$max_capture" \
      "$handler" /usr/bin/env "${environment[@]}" "$command" "$@"; then
    rm -rf -- "$directory"
    SF_RUN_HOOK_ERROR=$SF_PROCESS_ERROR
    return 1
  fi
  process=( "${reply[@]}" )
  SF_HOOK_RESULT+=( "${(@kv)process}" )
  if (( process[interrupted] )) || [[ $handler == : ]]; then
    rm -rf -- "$directory"
    return $(( process[interrupted] ? process[exit_code] : 0 ))
  fi
  output_bytes=$(( process[stdout_bytes] + process[stderr_bytes] ))
  if [[ $SF_HOOK_RESULT[error] == invalid ]]; then
    error="$lifecycle hook returned invalid control: $command"
  elif [[ -n $SF_HOOK_RESULT[error] ]]; then
    error=$SF_HOOK_RESULT[error]
  elif (( process[exit_code] )); then
    error="$lifecycle hook failed with status $process[exit_code]: $command"
    [[ ! -s $directory/stderr ]] || error+=": $(<"$directory/stderr")"
  elif (( process[control_bytes] > max_capture ||
      ! SF_HOOK_RESULT[final] && output_bytes > max_capture )); then
    error="$lifecycle hook output exceeds capture limit: $command"
  elif (( ! SF_HOOK_RESULT[final] && output_bytes )); then
    sf_run_hook_shortcut "$directory" || error=$REPLY
  fi
  rm -rf -- "$directory"
  # A draft that nothing settled leaves no trace.
  if (( SF_HOOK_RESULT[live] )); then
    sf_run_emit '{"type":"_hook_draft","lifecycle":"'$lifecycle'","id":"'$SF_RUN[hook_id]'","user_text":""}' ||
      error=${error:-cannot emit hook draft}
  fi
  [[ -z $error ]] || { SF_RUN_HOOK_ERROR=$error; return 1; }
}

# A match command decides by status alone and may write nothing.
sf_run_hook_match() {
  local session=$1 command=$2 input_file=$3 lifecycle=$4 turn_state=$5
  shift 5
  sf_run_hook_invoke "$session" "$command" "$input_file" "$lifecycle" \
    "$turn_state" : "$@" || return 2
  (( SF_HOOK_RESULT[stdout_bytes] + SF_HOOK_RESULT[stderr_bytes] +
     SF_HOOK_RESULT[control_bytes] == 0 &&
     (SF_HOOK_RESULT[exit_code] == 0 || SF_HOOK_RESULT[exit_code] == 1) )) || return 2
  (( SF_HOOK_RESULT[exit_code] == 0 ))
}

# Return the halting action's fields in reply after appending every settled
# record. No action leaves them empty.
sf_run_hooks() {
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local input_file command match_command error=''
  local -a plan
  integer offset invoke_status match_status

  SF_RUN_HOOK_ERROR=''
  SF_HOOK_RESULT=( action '' reason '' payload '' )
  if (( SF_RUN[hooks_known] )) &&
      [[ " $SF_RUN[hooks] " != *" $lifecycle "* ]]; then
    reply=( action '' )
    return 0
  fi
  sf_run_hook_project "$SF_RUN[runtime]" "$lifecycle" "$content" || {
    SF_RUN_HOOK_ERROR="cannot inspect $lifecycle hooks"
    return 1
  }
  plan=( "${reply[@]}" )
  if (( ! ${#plan} )); then
    reply=( action '' )
    return 0
  fi
  sf_scratch_file hook-input || { SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"; return 1; }
  input_file=$REPLY
  print -rn -- "$content" >"$input_file" || {
    rm -f -- "$input_file"
    SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"
    return 1
  }
  for (( offset = 1; offset <= ${#plan}; offset += 2 )); do
    command=$plan[offset]
    match_command=$plan[offset+1]
    if [[ -n $match_command ]]; then
      sf_run_hook_match "$session" "$match_command" "$input_file" \
        "$lifecycle" "$turn_state" "$@"
      match_status=$?
      (( match_status == 0 )) || {
        (( match_status == 1 )) && continue
        error="hook match command failed: $match_command"
        break
      }
    fi
    invoke_status=0
    sf_run_hook_invoke "$session" "$command" "$input_file" "$lifecycle" \
      "$turn_state" sf_run_hook_line "$@" || invoke_status=$?
    if (( invoke_status )); then
      if (( invoke_status == 129 || invoke_status == 130 || invoke_status == 143 )); then
        SF_RUN[signal_status]=$invoke_status
      fi
      error=${SF_RUN_HOOK_ERROR:-cannot run $lifecycle hook}
      break
    fi
    [[ -z $SF_HOOK_RESULT[action] ]] || break
  done
  rm -f -- "$input_file"
  if [[ -n $error ]]; then
    SF_RUN_HOOK_ERROR=$error
    return 1
  fi
  reply=( action "$SF_HOOK_RESULT[action]" reason "$SF_HOOK_RESULT[reason]"
    payload "$SF_HOOK_RESULT[payload]" )
}
