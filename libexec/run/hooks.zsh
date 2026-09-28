emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_run_component_begin] )) || source "$SF_ROOT/libexec/run/component.zsh"

typeset -g SF_RUN_HOOK_ERROR=''

# The lifecycle's invocation plan.
typeset -gA SF_HOOK_PLAN=()

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

sf_run_hook_manifest() {
  local command=$1 name=$2 lifecycle=$3 input=$4 id=$5 manifest
  sf_profile_manifest "${command:h}" || { REPLY=$SF_PROFILE_ERROR; return 1; }
  manifest=$(sf_jsonc_read "$REPLY" 2>&1) || { REPLY="invalid hook manifest: $command"; return 1; }
  REPLY=$(sf_jq -cn --argjson manifest "$manifest" --arg name "$name" \
    --arg lifecycle "$lifecycle" --arg input "$input" --arg id "$id" '
    include "lib/profile";
    include "lib/session";
    include "libexec/run/component";
    if $manifest | hook_manifest then
      component_plan($manifest; "hooks"; $name; $input; {type:"_draft",lifecycle:$lifecycle,id:$id})
    else error("invalid hook manifest") end
  ' 2>/dev/null) || { REPLY="invalid hook manifest: $command"; return 1; }
}

sf_run_hook_complete() {
  local directory=$1 outcome
  local -A settled
  sf_run_component_capture "$directory" "$SF_HOOK_PLAN[max_capture]" 0 ||
    { REPLY='cannot capture hook result'; return 1; }
  outcome=$REPLY
  sf_run_component_complete "$SF_COMPONENT[values]" "$outcome" ||
    { REPLY='cannot decode hook result'; return 1; }
  settled=( "${reply[@]}" )
  if [[ -n $settled[result] ]]; then
    sf_run_append "$SF_COMPONENT[session]" "$settled[result]" || return
    (( SF_RUN[hook_id] += 1 ))
    SF_COMPONENT[live]=0
    [[ $settled[model_feedback] != true ]] || SF_COMPONENT[model_feedback]=1
  fi
}

# Run each hook with the lifecycle's original input and arguments. A successful
# action ends the list; no action leaves reply empty.
sf_run_hooks() {
  setopt local_options no_err_exit
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local command input config_dir directory='' error='' name component
  local -a hooks environment
  local -A process SF_COMPONENT=( action '' reason '' payload '' live 0 )
  integer max_capture model_feedback=0

  SF_RUN_HOOK_ERROR=''
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
      [[ -d $command && -x $command/run ]] || {
        error="hook command is not executable: $command"
        break
      }
      if [[ $command == "$SF_SHARE/hooks/"* ]]; then
        name=${command#"$SF_SHARE/hooks/"}
      elif [[ $command == "$config_dir/hooks/"* ]]; then
        name=${command#"$config_dir/hooks/"}
      else
        name=$command
      fi
      sf_run_hook_manifest "$command/run" "$name" "$lifecycle" "$content" \
        "$SF_RUN[hook_id]" || { error=$REPLY; break; }
      component=$REPLY
      sf_scratch_directory hook || { error='cannot prepare hook capture'; break; }
      directory=$REPLY
      process=()
      sf_run_component_begin "$session" "$component" ||
        error='cannot emit hook draft'
      if [[ -z $error ]] && sf_process_run "$directory" "${SF_RUN[cwd]:A}" "$input" "$max_capture" \
          sf_run_component_line /usr/bin/env "${environment[@]}" "$command/run" "$@"; then
        process=( "${reply[@]}" )
        if (( process[interrupted] )); then
          SF_RUN[signal_status]=$process[exit_code]
          error="cannot run $lifecycle hook"
        elif [[ $SF_COMPONENT[error] == invalid ]]; then
          error="$lifecycle hook returned invalid control: $command"
        elif [[ -n $SF_COMPONENT[error] ]]; then
          error=$SF_COMPONENT[error]
        elif (( process[exit_code] )); then
          error="$lifecycle hook failed with status $process[exit_code]: $command"
          [[ ! -s $directory/stderr ]] || error+=": $(<"$directory/stderr")"
        elif (( process[control_bytes] > max_capture )); then
          error="$lifecycle hook output exceeds capture limit: $command"
        else
          sf_run_hook_complete "$directory" || error=$REPLY
        fi
      elif [[ -z $error ]]; then
        error=$SF_PROCESS_ERROR
      fi
      rm -rf -- "$directory"
      directory=''
      # A draft that nothing settled leaves no trace.
      sf_run_component_clear || error=${error:-cannot emit hook draft}
      (( model_feedback |= SF_COMPONENT[model_feedback] ))
      [[ -z $error && -z $SF_COMPONENT[action] ]] || break
    done
  fi
  rm -f -- "$input"
  if [[ -z $error && $lifecycle == stop && $SF_COMPONENT[action] == continue ]] &&
      (( ! model_feedback )); then
    error='stop hook continued without model feedback'
  fi
  [[ -z $error ]] || { SF_RUN_HOOK_ERROR=$error; return 1; }
  reply=( action "$SF_COMPONENT[action]" reason "$SF_COMPONENT[reason]"
    payload "$SF_COMPONENT[payload]" )
}
