emulate -R zsh
setopt no_aliases no_bg_nice no_multios pipe_fail

(( $+functions[sf_environment_load] )) || source "$SF_ROOT/lib/environment.zsh"
(( $+functions[sf_process_run] )) || source "$SF_ROOT/lib/process.zsh"
(( $+functions[sf_scratch_directory] )) || source "$SF_ROOT/lib/scratch.zsh"
(( $+functions[sf_run_component_update] )) || source "$SF_ROOT/libexec/run/component.zsh"

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

sf_run_hook_manifest() {
  local command=$1 name=$2 manifest
  sf_profile_manifest "${command:h}" || { REPLY=$SF_PROFILE_ERROR; return 1; }
  manifest=$(sf_jsonc_read "$REPLY" 2>&1) || { REPLY="invalid hook manifest: $command"; return 1; }
  sf_jq_fields -cn --argjson manifest "$manifest" '
    include "lib/fields";
    include "lib/profile";
    if $manifest | hook_manifest then
      entry("templates"; {user_text:($manifest.user_text // ""),
        user_text_done:($manifest.user_text_done // ""),
        user_text_skipped:($manifest.user_text_skipped // ""),
        model_text:($manifest.model_text // "")} | tojson),
      entry("preview"; $manifest.user_preview_lines // null | tojson),
      ("ok" | field)
    else error("invalid hook manifest") end
  ' || { REPLY="invalid hook manifest: $command"; return 1; }
  SF_HOOK_PLAN=( "${reply[@]}" )
  SF_HOOK_PLAN[name]=$name
}

# Apply one hook fd 3 line as it arrives. State is durable before settlement.
sf_run_hook_line() {
  local record lifecycle=$SF_HOOK_RESULT[lifecycle] id=$SF_RUN[hook_id]
  local -A line
  [[ -z $SF_HOOK_RESULT[error] ]] || return 0
  sf_run_component_update "$1" "$lifecycle" "$SF_HOOK_RESULT[data]" \
    "$SF_HOOK_RESULT[templates]" '[]' "$SF_HOOK_PLAN[preview]" \
    "$SF_HOOK_PLAN[name]" "$SF_HOOK_RESULT[input]" \
    "{\"type\":\"_draft\",\"lifecycle\":\"$lifecycle\",\"id\":\"$id\"}" ||
    { SF_HOOK_RESULT[error]='cannot decode hook output'; return 1; }
  line=( "${reply[@]}" )
  [[ $line[valid] == true ]] || { SF_HOOK_RESULT[error]=invalid; return 1; }
  for record in ${(f)line[states]}; do
    sf_run_append "$SF_HOOK_RESULT[session]" "$record" ||
      { SF_HOOK_RESULT[error]=$REPLY; return 1; }
  done
  SF_HOOK_RESULT+=( data "$line[data]" templates "$line[templates]" )
  sf_run_emit "$line[draft]" || { SF_HOOK_RESULT[error]='cannot emit hook draft'; return 1; }
  SF_HOOK_RESULT[live]=1
  [[ -z $line[action] ]] || SF_HOOK_RESULT+=( action "$line[action]"
    reason "$line[reason]" payload "$line[payload]" )
}

sf_run_hook_complete() {
  local directory=$1
  local -A settled
  local stdout="$directory/stdout.bounded" stderr="$directory/stderr.bounded"
  sf_run_component_bound "$directory/stdout" "$stdout" "$SF_HOOK_PLAN[max_capture]" ||
    { REPLY='cannot bound hook stdout'; return 1; }
  sf_run_component_bound "$directory/stderr" "$stderr" "$SF_HOOK_PLAN[max_capture]" ||
    { REPLY='cannot bound hook stderr'; return 1; }
  sf_jq_fields -cn --rawfile stdout "$stdout" --rawfile stderr "$stderr" \
    --arg lifecycle "$SF_HOOK_RESULT[lifecycle]" --arg id "$SF_RUN[hook_id]" \
    --arg name "$SF_HOOK_PLAN[name]" --argjson input "$SF_HOOK_RESULT[input]" \
    --argjson data "$SF_HOOK_RESULT[data]" \
    --argjson templates "$SF_HOOK_RESULT[templates]" \
    --argjson preview "$SF_HOOK_PLAN[preview]" \
    --argjson exit_code 0 '
      include "lib/fields";
      include "lib/session";
      include "lib/profile";
      include "libexec/run/component";
      (component_render($templates; true; $name; $input;
        {stdout:$stdout,stderr:$stderr,exit_code:$exit_code}; $data; $preview)) as $texts |
      ({type:"hook_result",lifecycle:$lifecycle,id:$id} + $texts) as $result |
      if $result | canonical_hook_result then
        entry("record"; if $texts.user_text == null and $texts.model_text == null
          then "" else $result | tojson end),
      entry("model_feedback"; $texts.model_text != null | tostring),
      ("ok" | field)
      else error("invalid hook result") end
    ' || { REPLY='cannot decode hook result'; return 1; }
  settled=( "${reply[@]}" )
  if [[ -n $settled[record] ]]; then
    sf_run_append "$SF_HOOK_RESULT[session]" "$settled[record]" || return
    (( SF_RUN[hook_id] += 1 ))
    SF_HOOK_RESULT[live]=0
    [[ $settled[model_feedback] != true ]] || SF_HOOK_RESULT[model_feedback]=1
  fi
}

# Run each hook with the lifecycle's original input and arguments. A successful
# action ends the list; no action leaves reply empty.
sf_run_hooks() {
  setopt local_options no_err_exit
  local session=$1 lifecycle=$2 content=$3 turn_state=$4
  shift 4
  local command input config_dir directory='' error='' name
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
      sf_run_hook_manifest "$command/run" "$name" || { error=$REPLY; break; }
      SF_HOOK_PLAN[max_capture]=$max_capture
      sf_scratch_directory hook || { error='cannot prepare hook capture'; break; }
      directory=$REPLY
      process=()
      SF_HOOK_RESULT=( session "$session" lifecycle "$lifecycle" error '' live 0
        model_feedback 0 input "$(jq -Rn --arg text "$content" '$text')"
        data '{}' templates "$SF_HOOK_PLAN[templates]" action '' reason '' payload '' )
      if ! sf_process_run "$directory" "${SF_RUN[cwd]:A}" "$input" "$max_capture" \
          sf_run_hook_line /usr/bin/env "${environment[@]}" "$command/run" "$@"; then
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
        elif (( process[control_bytes] > max_capture )); then
          error="$lifecycle hook output exceeds capture limit: $command"
        else
          sf_run_hook_complete "$directory" || error=$REPLY
        fi
      fi
      rm -rf -- "$directory"
      directory=''
      # A draft that nothing settled leaves no trace.
      if (( SF_HOOK_RESULT[live] )); then
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
