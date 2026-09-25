emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

# The lifecycle's plan and the running hook's outcome, both keyed by name.
typeset -gA SF_HOOK_PLAN=() SF_HOOK_RESULT=()

sf_run_hook_project() {
  local profile=$1 lifecycle=$2
  sf_jq_fields -rn --argjson profile "$profile" --arg lifecycle "$lifecycle" '
      include "lib/fields";
      entry("max_capture"; $profile.max_capture_bytes | tostring),
      entry("model"; $profile.request.model),
      entry("profile_env"; $profile.env | tojson),
      entry("hooks"; $profile.hooks[$lifecycle] // [] | join("\n")),
      ("ok" | field)
    ' || return 1
  SF_HOOK_PLAN=( "${reply[@]}" )
}

# A settled result takes the live section's id and opens the next one. Settled
# model text is feedback.
sf_run_hook_settle() {
  sf_run_append "$SF_HOOK_RESULT[session]" "$1" || return
  (( SF_RUN[hook_id] += 1 ))
  SF_HOOK_RESULT[live]=0
  [[ $2 != true ]] || SF_HOOK_RESULT[model_feedback]=1
}

# Decode one fd 3 line for a hook or tool against the live section's VIEW.
# DRAFT is the transient event a user text fills in, RESULT the record a
# finalized view fills in, and PREVIEW the live section's hint. LIFECYCLE is
# empty for a tool.
sf_run_component_line() {
  sf_jq_fields -cn --arg line "$1" --arg lifecycle "$2" --argjson view "$3" \
    --argjson draft "$4" --argjson result "$5" --argjson preview "$6" '
      include "lib/fields";
      include "lib/session";
      include "libexec/run/component";
      ($line | try fromjson catch null | component_line(
        if $lifecycle == "" then null else $lifecycle end; $view; $draft; $preview)) as $line |
      entry("valid"; $line != null | tostring),
      entry("states"; [$line.states[]? | tojson] | join("\n")),
      entry("view"; $line.view | tojson),
      entry("owned"; $line.view // {} | has("user_text") and has("model_text") | tostring),
      entry("record"; $line.record | if . == null then "" else $result + . | tojson end),
      entry("model_feedback"; $line.record.model_text != null | tostring),
      entry("draft"; $line.draft | if . == null then "" else tojson end),
      entry("preview"; $line.preview | tojson),
      entry("action"; $line.control.action // ""),
      entry("reason"; $line.control.reason // ""),
      entry("payload"; $line.control | (.argv // .profile) |
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
  sf_run_component_line "$1" "$lifecycle" "$SF_HOOK_RESULT[view]" \
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
  SF_HOOK_RESULT+=( view "$line[view]" owned "$line[owned]" preview "$line[preview]" )
  if [[ -n $line[record] ]]; then
    sf_run_hook_settle "$line[record]" "$line[model_feedback]" || { SF_HOOK_RESULT[error]=$REPLY; return 1; }
  elif [[ -n $line[draft] ]]; then
    sf_run_emit "$line[draft]" || { SF_HOOK_RESULT[error]='cannot emit hook draft'; return 1; }
    SF_HOOK_RESULT[live]=1
  fi
  [[ -z $line[action] ]] || SF_HOOK_RESULT+=( action "$line[action]"
    reason "$line[reason]" payload "$line[payload]" )
}

# The trailing section settles at exit 0: the user sees stdout and stderr and
# the model sees stdout, unless the hook wrote its own.
sf_run_hook_trailing() {
  local directory=$1
  local -A settled
  sf_jq_fields -cn --rawfile stdout "$directory/stdout" --rawfile stderr "$directory/stderr" \
    --arg lifecycle "$SF_HOOK_RESULT[lifecycle]" --arg id "$SF_RUN[hook_id]" \
    --argjson view "$SF_HOOK_RESULT[view]" --argjson preview "$SF_HOOK_RESULT[preview]" '
      include "lib/fields";
      include "libexec/run/component";
      ($view | component_texts($stdout + $stderr; $stdout; $preview)) as $texts |
      entry("record"; $texts | if . == null then "" else
        {type:"hook_result",lifecycle:$lifecycle,id:$id} + . | tojson end),
      entry("model_feedback"; $texts.model_text != null | tostring),
      ("ok" | field)
    ' || { REPLY='cannot decode hook result'; return 1; }
  settled=( "${reply[@]}" )
  [[ -z $settled[record] ]] || sf_run_hook_settle "$settled[record]" "$settled[model_feedback]"
}

# Run each hook with the lifecycle's original input and arguments. A successful
# action ends the list; no action leaves reply empty.
sf_run_hooks() {
  setopt local_options no_err_exit
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local command input config_dir directory='' error=''
  local -a hooks environment
  local -A process
  integer max_capture model_feedback=0

  SF_RUN_HOOK_ERROR=''
  SF_HOOK_RESULT=( action '' reason '' payload '' live 0 )
  reply=( action '' reason '' payload '' )
  if (( SF_RUN[hooks_known] )) &&
      [[ " $SF_RUN[hooks] " != *" $lifecycle "* ]]; then
    return 0
  fi
  sf_run_hook_project "$SF_RUN[profile]" "$lifecycle" || {
    SF_RUN_HOOK_ERROR="cannot inspect $lifecycle hooks"
    return 1
  }
  hooks=( ${(f)SF_HOOK_PLAN[hooks]} )
  (( ${#hooks} )) || return 0
  max_capture=$SF_HOOK_PLAN[max_capture]
  sf_environment_load '' "$SF_HOOK_PLAN[profile_env]" || {
    SF_RUN_HOOK_ERROR=$SF_ENVIRONMENT_ERROR
    return 1
  }
  config_dir=$REPLY
  sf_scratch_file hook-input || { SF_RUN_HOOK_ERROR="cannot prepare $lifecycle hook input"; return 1; }
  input=${REPLY:A}
  # Core values follow configured values so that they win.
  environment=(
    "${SF_ENVIRONMENT_VALUES[@]}"
    "SHELLFISH_SESSION=${session:A}"
    "SHELLFISH_MAX_CAPTURE_BYTES=$max_capture"
    "SHELLFISH_MODEL=$SF_HOOK_PLAN[model]"
    "SHELLFISH_EXECUTABLE=$SF_ENTRY"
    "SHELLFISH_MODE=${SHELLFISH_MODE-}"
    "SHELLFISH_VERBOSE=${SHELLFISH_VERBOSE:-0}"
    "SHELLFISH_CONFIG_DIR=$config_dir"
    "SHELLFISH_SHARE_DIR=$SF_SHARE"
  )
  if [[ $lifecycle != session_start ]]; then
    environment+=( "SHELLFISH_TURN_ID=$SF_RUN[turn_id]" "SHELLFISH_TURN_STATE=$turn_state" )
  else
    environment=( -u SHELLFISH_TURN_ID -u SHELLFISH_TURN_STATE "${environment[@]}" )
  fi
  if ! print -rn -- "$content" >"$input"; then
    error="cannot prepare $lifecycle hook input"
  else
    for command in "${hooks[@]}"; do
      [[ -f $command && -x $command ]] || {
        error="hook command is not executable: $command"
        break
      }
      sf_scratch_directory hook || { error='cannot prepare hook capture'; break; }
      directory=$REPLY
      process=()
      SF_HOOK_RESULT=( session "$session" lifecycle "$lifecycle" error '' live 0
        model_feedback 0 view '{}' owned false preview null action '' reason '' payload '' )
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
        elif [[ $SF_HOOK_RESULT[owned] != true ]] &&
            (( process[stdout_bytes] + process[stderr_bytes] > max_capture )) ||
            (( process[control_bytes] > max_capture )); then
          error="$lifecycle hook output exceeds capture limit: $command"
        else
          sf_run_hook_trailing "$directory" || error=$REPLY
        fi
      fi
      rm -rf -- "$directory"
      directory=''
      # A draft that nothing settled leaves no trace.
      if (( SF_HOOK_RESULT[live] && ! process[interrupted] )); then
        sf_run_emit '{"type":"_draft","lifecycle":"'$lifecycle'","id":"'$SF_RUN[hook_id]'","user_text":""}' ||
          error=${error:-cannot emit hook draft}
      fi
      (( model_feedback |= SF_HOOK_RESULT[model_feedback] ))
      [[ -z $error && -z $SF_HOOK_RESULT[action] ]] || break
    done
  fi
  rm -f -- "$input"
  if [[ -z $error && $lifecycle == stop && $SF_HOOK_RESULT[action] == continue ]] &&
      (( ! model_feedback )); then
    error='stop hook continued without model feedback'
  fi
  [[ -z $error ]] || { SF_RUN_HOOK_ERROR=$error; return 1; }
  reply=( action "$SF_HOOK_RESULT[action]" reason "$SF_HOOK_RESULT[reason]"
    payload "$SF_HOOK_RESULT[payload]" )
}
