emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

# The lifecycle's plan and the running hook's outcome, both keyed by name.
typeset -gA SF_HOOK_PLAN=() SF_HOOK_RESULT=()

sf_run_hook_project() {
  local runtime=$1 lifecycle=$2
  sf_jq_fields -rn --argjson runtime "$runtime" --arg lifecycle "$lifecycle" '
      include "lib/fields";
      entry("max_capture"; $runtime.harness.max_capture_bytes | tostring),
      entry("model"; $runtime.request.model),
      entry("hooks"; $runtime.harness[$lifecycle] // [] | join("\n")),
      ("ok" | field)
    ' || return 1
  SF_HOOK_PLAN=( "${reply[@]}" )
}

# A settled result takes the live section's id and opens the next one.
sf_run_hook_settle() {
  sf_run_append "$SF_HOOK_RESULT[session]" "$1" || return
  (( SF_RUN[hook_id] += 1 ))
  SF_HOOK_RESULT[live]=0
  SF_HOOK_RESULT[preview]=null
}

# Decode one fd 3 line for a hook or tool. DRAFT is the transient event a draft
# fills in, RESULT the record a final with text fills in, and PREVIEW the live
# section's hint. LIFECYCLE is empty for a tool.
sf_run_component_line() {
  sf_jq_fields -cn --arg line "$1" --arg lifecycle "$2" --argjson draft "$3" \
    --argjson result "$4" --argjson preview "${5:-null}" '
      include "lib/fields";
      include "lib/session";
      include "libexec/run/component";
      ($line | try fromjson catch null |
        component_line(if $lifecycle == "" then null else $lifecycle end; $draft; $preview)) as $line |
      entry("valid"; $line != null | tostring),
      entry("states"; [$line.states[]? | tojson] | join("\n")),
      entry("texts"; $line.texts | if . == null then "" else tojson end),
      entry("record"; $line.texts |
        if has("user_text") or has("model_text") then $result + . | tojson else "" end),
      entry("draft"; $line.draft | if . == null then "" else tojson end),
      entry("preview"; $line.preview | tojson),
      entry("action"; $line.control.action // ""),
      entry("reason"; $line.control.reason // ""),
      entry("payload"; $line.control | (.argv // .runtime) |
        if . == null then "" else tojson end),
      ("ok" | field)
    '
}

# Apply one hook fd 3 line as it arrives. After an invalid line the rest are
# ignored and the hook fails at exit.
sf_run_hook_line() {
  local record lifecycle=$SF_HOOK_RESULT[lifecycle] id=$SF_RUN[hook_id]
  local -A line
  [[ -z $SF_HOOK_RESULT[error] ]] || return 0
  sf_run_component_line "$1" "$lifecycle" \
    '{"type":"_draft","lifecycle":"'$lifecycle'","id":"'$id'"}' \
    '{"type":"hook_result","lifecycle":"'$lifecycle'","id":"'$id'"}' \
    "$SF_HOOK_RESULT[preview]" ||
    { SF_HOOK_RESULT[error]='cannot decode hook output'; return 1; }
  line=( "${reply[@]}" )
  [[ $line[valid] == true ]] || { SF_HOOK_RESULT[error]=invalid; return 1; }
  for record in ${(f)line[states]}; do
    sf_run_append "$SF_HOOK_RESULT[session]" "$record" ||
      { SF_HOOK_RESULT[error]=$REPLY; return 1; }
  done
  SF_HOOK_RESULT[preview]=$line[preview]
  if [[ -n $line[record] ]]; then
    sf_run_hook_settle "$line[record]" || { SF_HOOK_RESULT[error]=$REPLY; return 1; }
  elif [[ -n $line[draft] ]]; then
    sf_run_emit "$line[draft]" || { SF_HOOK_RESULT[error]='cannot emit hook draft'; return 1; }
    SF_HOOK_RESULT[live]=1
  fi
  [[ -z $line[texts] ]] || SF_HOOK_RESULT[final]=1
  [[ -z $line[action] ]] || SF_HOOK_RESULT+=( action "$line[action]"
    reason "$line[reason]" payload "$line[payload]" )
}

# Without a final, stdout and stderr settle as one result: the user sees both
# and the model sees stdout.
sf_run_hook_shortcut() {
  local directory=$1 record
  record=$(sf_jq -cn --rawfile stdout "$directory/stdout" --rawfile stderr "$directory/stderr" \
    --arg lifecycle "$SF_HOOK_RESULT[lifecycle]" --arg id "$SF_RUN[hook_id]" \
    --argjson preview "${SF_HOOK_RESULT[preview]:-null}" '
      {type:"hook_result",lifecycle:$lifecycle,id:$id} +
      (if $stdout + $stderr == "" then {} else {user_text:($stdout + $stderr)} end) +
      (if $stdout == "" then {} else {model_text:$stdout} end) +
      (if $preview == null then {} else {user_preview_lines:$preview} end)
    ') || { REPLY='cannot decode hook result'; return 1; }
  sf_run_hook_settle "$record"
}

# Run the lifecycle's first hook. Each later one is the parent of the one before,
# reached through SHELLFISH_PARENT_HOOK. Return the last action's fields in
# reply after appending every settled record; no action leaves them empty.
sf_run_hooks() {
  setopt local_options no_err_exit
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local command input config_dir directory='' error=''
  local -a hooks environment
  local -A process
  integer max_capture

  SF_RUN_HOOK_ERROR=''
  SF_HOOK_RESULT=( action '' reason '' payload '' live 0 )
  reply=( action '' reason '' payload '' )
  if (( SF_RUN[hooks_known] )) &&
      [[ " $SF_RUN[hooks] " != *" $lifecycle "* ]]; then
    return 0
  fi
  sf_run_hook_project "$SF_RUN[runtime]" "$lifecycle" || {
    SF_RUN_HOOK_ERROR="cannot inspect $lifecycle hooks"
    return 1
  }
  hooks=( ${(f)SF_HOOK_PLAN[hooks]} )
  (( ${#hooks} )) || return 0
  command=$hooks[1]
  max_capture=$SF_HOOK_PLAN[max_capture]
  [[ -f $command && -x $command ]] || {
    SF_RUN_HOOK_ERROR="hook command is not executable: $command"
    return 1
  }
  sf_environment_load || {
    SF_RUN_HOOK_ERROR=$SF_ENVIRONMENT_ERROR
    return 1
  }
  config_dir=$REPLY
  sf_scratch_file hook-input || { SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"; return 1; }
  input=${REPLY:A}
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
    "SHELLFISH_DEFAULT_DIR=$SF_SHARE/profiles/default"
  )
  if [[ $lifecycle != session_start ]]; then
    environment+=( "SHELLFISH_TURN_ID=$SF_RUN[turn_id]" "SHELLFISH_TURN_STATE=$turn_state" )
  else
    environment=( -u SHELLFISH_TURN_ID -u SHELLFISH_TURN_STATE "${environment[@]}" )
  fi
  # libexec/run/parent-hook reopens the input for each parent in turn.
  if (( ${#hooks} > 1 )); then
    environment+=( "SHELLFISH_PARENT_HOOK=$SF_ROOT/libexec/run/parent-hook"
      "SHELLFISH_PARENT_HOOKS=${(F)hooks[2,-1]}" "SHELLFISH_HOOK_INPUT=$input" )
  else
    environment=( -u SHELLFISH_PARENT_HOOK "${environment[@]}" )
  fi
  if ! print -rn -- "$content" >"$input"; then
    error="cannot prepare $lifecycle hook input"
  elif ! sf_scratch_directory hook; then
    error='cannot prepare hook capture'
  else
    directory=$REPLY
    SF_HOOK_RESULT=( session "$session" lifecycle "$lifecycle" error '' final 0 live 0
      preview null action '' reason '' payload '' )
    if ! sf_process_run "$directory" "${SF_RUN[cwd]:A}" "$input" "$max_capture" \
        sf_run_hook_line /usr/bin/env "${environment[@]}" "$command" "$@"; then
      error=$SF_PROCESS_ERROR
    else
      process=( "${reply[@]}" )
      if (( process[interrupted] )); then
        SF_RUN[signal_status]=$process[exit_code]
        error="cannot run $lifecycle hook"
      elif [[ $SF_HOOK_RESULT[error] == invalid ]]; then
        error="$lifecycle hook returned invalid control: $command"
      elif [[ -n $SF_HOOK_RESULT[error] ]]; then
        error=$SF_HOOK_RESULT[error]
      elif (( process[exit_code] )); then
        error="$lifecycle hook failed with status $process[exit_code]: $command"
        [[ ! -s $directory/stderr ]] || error+=": $(<"$directory/stderr")"
      elif (( process[control_bytes] > max_capture || ! SF_HOOK_RESULT[final] &&
          process[stdout_bytes] + process[stderr_bytes] > max_capture )); then
        error="$lifecycle hook output exceeds capture limit: $command"
      elif (( ! SF_HOOK_RESULT[final] && process[stdout_bytes] + process[stderr_bytes] )); then
        sf_run_hook_shortcut "$directory" || error=$REPLY
      fi
    fi
  fi
  rm -f -- "$input"
  [[ -z $directory ]] || rm -rf -- "$directory"
  # A draft that nothing settled leaves no trace.
  if (( SF_HOOK_RESULT[live] && ! process[interrupted] )); then
    sf_run_emit '{"type":"_draft","lifecycle":"'$lifecycle'","id":"'$SF_RUN[hook_id]'","user_text":""}' ||
      error=${error:-cannot emit hook draft}
  fi
  [[ -z $error ]] || { SF_RUN_HOOK_ERROR=$error; return 1; }
  reply=( action "$SF_HOOK_RESULT[action]" reason "$SF_HOOK_RESULT[reason]"
    payload "$SF_HOOK_RESULT[payload]" )
}
